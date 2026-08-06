#!/usr/bin/env bats
# tests/phyllary/glean.bats — acceptance tests for phyllary glean (dotfiles-dft.6)

load 'helpers.bash'

setup() {
	git_sandbox
	PHYLLARY="$BATS_TEST_DIRNAME/../../bin/phyllary"
	export PHYLLARY_TEST_TRANSCRIPT_DIR="${BATS_TEST_TMPDIR}/transcripts"
	mkdir -p "${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${BATS_TEST_TMPDIR}/phyllary-glean-state"
	mkdir -p "${PHYLLARY_GLEAN_STATE_DIR}"
	# Avoid launching a real model in tests; the mocked judgment fork reads stdin and
	# emits no candidates (successful no-finding fork).
	export PHYLLARY_GLEAN_JUDGMENT_CMD='cat >/dev/null; echo "{\"type\":\"none\",\"reason\":\"test\"}"'
}

# Helper: write a transcript file with N JSONL lines
write_transcript() { # $1=file $2=lines...
	local file="$1"
	shift
	for line in "$@"; do
		printf '%s\n' "$line" >>"$file"
	done
}

# Helper: write a transcript line with is_error=true
write_error_line() { # $1=file $2=command $3=error_msg
	local file="$1" cmd="$2" err="$3"
	local uuid
	uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
	printf '{"type":"user","message":{"role":"user","content":"run %s"},"timestamp":"2026-07-10T12:00:00.000Z","sessionId":"test"}\n' "$cmd" >>"$file"
	printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"%s"}}]},"timestamp":"2026-07-10T12:00:01.000Z","sessionId":"test"}\n' "$uuid" "$cmd" >>"$file"
	printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s","is_error":true}],"timestamp":"2026-07-10T12:00:02.000Z","sessionId":"test"}\n' "$uuid" "$err" >>"$file"
}

# Helper: create a minimal valid transcript with some errors
create_test_transcripts() {
	local base_dir="$1"
	mkdir -p "${base_dir}/session-main"
	write_transcript "${base_dir}/session-main/transcript.jsonl" \
		'{"type":"mode","mode":"normal","sessionId":"main","timestamp":"2026-07-10T10:00:00.000Z"}' \
		'{"type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-07-10T10:00:01.000Z","sessionId":"main"}' \
		'{"type":"assistant","message":{"role":"assistant","content":"hi"},"timestamp":"2026-07-10T10:00:02.000Z","sessionId":"main"}'
	write_error_line "${base_dir}/session-main/transcript.jsonl" "grep -r foo" "grep: foo: No such file or directory"
	write_transcript "${base_dir}/session-main/transcript.jsonl" \
		'{"type":"user","message":{"role":"user","content":"done"},"timestamp":"2026-07-10T10:00:05.000Z","sessionId":"main"}'
}

@test "glean: refuses when not in a git repo" {
	cd /tmp
	run "$PHYLLARY" glean
	[ "$status" -eq 4 ]
	[[ "$output" == *"not inside a git repository"* ]]
}

@test "glean: refuses when .phyllary marker missing" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	run "$PHYLLARY" glean
	[ "$status" -eq 4 ]
	[[ "$output" == *"missing .phyllary marker"* ]]
}

@test "glean: runs without error on empty transcript dir (no captures filed)" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	[[ "$output" == *"phyllary: glean"* ]] || [[ "$output" == *"glean"* ]]
}

@test "glean: default Claude judgment fork uses cheap bounded model" {
	local tmpdir stub_bin args_file
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	stub_bin="${BATS_TEST_TMPDIR}/bin"
	args_file="${BATS_TEST_TMPDIR}/claude-args.txt"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PHYLLARY_STUB_CLAUDE_ARGS"
cat >/dev/null
printf '{"type":"none","reason":"stub"}\n'
SH
	chmod +x "$stub_bin/claude"
	export PATH="$stub_bin:$PATH"
	export PHYLLARY_STUB_CLAUDE_ARGS="$args_file"
	unset PHYLLARY_GLEAN_JUDGMENT_CMD
	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1
	create_test_transcripts "${PHYLLARY_TEST_TRANSCRIPT_DIR}"

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	grep -qx -- '--model' "$args_file"
	grep -qx -- 'haiku' "$args_file"
	grep -qx -- '--max-budget-usd' "$args_file"
	grep -qx -- '0.05' "$args_file"
}

@test "glean: flock - two simultaneous invocations, only one harvests" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	create_test_transcripts "${PHYLLARY_TEST_TRANSCRIPT_DIR}"

	# Hold the lock long enough that the second invocation collides with it.
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1
	export PHYLLARY_GLEAN_JUDGMENT_CMD='sleep 1; cat >/dev/null; echo "{\"type\":\"none\",\"reason\":\"test\"}"'
	local out1="${BATS_TEST_TMPDIR}/glean-1.out" out2="${BATS_TEST_TMPDIR}/glean-2.out"
	"$PHYLLARY" glean >"$out1" 2>&1 &
	local pid1=$!
	sleep 0.1
	"$PHYLLARY" glean >"$out2" 2>&1 &
	local pid2=$!
	wait "$pid1"
	wait "$pid2"

	local locked_count scanning_count
	locked_count=$(grep -h -c 'another instance is running' "$out1" "$out2" | paste -sd+ - | bc)
	scanning_count=$(grep -h -c '^glean: scanning ' "$out1" "$out2" | paste -sd+ - | bc)
	[ "$locked_count" -eq 1 ]
	[ "$scanning_count" -eq 1 ]

	local watermarks
	watermarks=$(find "${PHYLLARY_GLEAN_STATE_DIR}" -name '*.watermark' 2>/dev/null)
	[ -n "$watermarks" ]
}

@test "glean: kill mid-harvest leaves watermark unmoved; next run re-harvests" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	create_test_transcripts "${PHYLLARY_TEST_TRANSCRIPT_DIR}"

	# Start a harvest whose judgment fork blocks, then kill it before the fork can finish.
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1
	export PHYLLARY_GLEAN_JUDGMENT_CMD='sleep 5; cat >/dev/null; echo "{\"type\":\"none\",\"reason\":\"test\"}"'
	"$PHYLLARY" glean >"${BATS_TEST_TMPDIR}/killed.out" 2>&1 &
	local pid=$!
	sleep 0.2
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	# Watermark is still absent because the fork never completed.
	[ -z "$(find "${PHYLLARY_GLEAN_STATE_DIR}" -name '*.watermark' -print -quit 2>/dev/null)" ]

	# A later successful run sees the same chunk and advances the watermark.
	export PHYLLARY_GLEAN_JUDGMENT_CMD='cat >/dev/null; echo "{\"type\":\"none\",\"reason\":\"test\"}"'
	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	[ -n "$(find "${PHYLLARY_GLEAN_STATE_DIR}" -name '*.watermark' -print -quit 2>/dev/null)" ]
}

@test "glean: /clear-orphaned transcript segment is harvested" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	local clear_dir="${PHYLLARY_TEST_TRANSCRIPT_DIR}/session-clear"
	mkdir -p "$clear_dir"
	write_transcript "${clear_dir}/transcript.jsonl" \
		'{"type":"mode","mode":"normal","sessionId":"clear","timestamp":"2026-07-10T10:00:00.000Z"}' \
		'{"type":"user","message":{"role":"user","content":"/clear"},"timestamp":"2026-07-10T10:00:01.000Z","sessionId":"clear"}' \
		'{"type":"system","subtype":"clear_orphaned","timestamp":"2026-07-10T10:00:02.000Z","sessionId":"clear"}'
	write_error_line "${clear_dir}/transcript.jsonl" "cat /nonexistent" "cat: /nonexistent: No such file or directory"

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	[ -n "$(find "${PHYLLARY_GLEAN_STATE_DIR}" -name '*.watermark' -print -quit 2>/dev/null)" ]
}

@test "glean: sub-threshold chunk skipped and logged (no silent caps)" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	local small_dir="${PHYLLARY_TEST_TRANSCRIPT_DIR}/session-tiny"
	mkdir -p "$small_dir"
	# Very small transcript - below minimum chunk size
	write_transcript "${small_dir}/transcript.jsonl" \
		'{"type":"mode","mode":"normal","sessionId":"tiny","timestamp":"2026-07-10T10:00:00.000Z"}'

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	[[ "$output" == *"sub-threshold chunk skipped"* ]]
}

@test "glean: exactly-once - no transcript line harvested twice across runs" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	create_test_transcripts "${PHYLLARY_TEST_TRANSCRIPT_DIR}"

	# Run glean twice; the second run sees the watermark and cannot advance or reprocess.
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1
	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	local first_watermark
	first_watermark=$(cat "${PHYLLARY_GLEAN_STATE_DIR}"/*.watermark 2>/dev/null | sort)

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	local second_watermark
	second_watermark=$(cat "${PHYLLARY_GLEAN_STATE_DIR}"/*.watermark 2>/dev/null | sort)
	[ "$first_watermark" = "$second_watermark" ]
	[[ "$output" != *"sub-threshold chunk skipped"* ]]
}

@test "glean: appended transcript lines are harvested from the saved offset" {
	local tmpdir transcript
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	transcript="${PHYLLARY_TEST_TRANSCRIPT_DIR}/session.jsonl"
	write_transcript "$transcript" '{"type":"mode","sessionId":"first"}'
	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	[ "$(cat "${PHYLLARY_GLEAN_STATE_DIR}"/*.watermark)" -eq 1 ]

	printf '%s\n' '{"type":"mode","sessionId":"second"}' >>"$transcript"
	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	[[ "$output" == *"lines 2-2"* ]]
	[ "$(cat "${PHYLLARY_GLEAN_STATE_DIR}"/*.watermark)" -eq 2 ]
}

@test "glean: malformed judgment output does not advance the watermark" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1
	export PHYLLARY_GLEAN_JUDGMENT_CMD='cat >/dev/null; echo not-json'
	create_test_transcripts "${PHYLLARY_TEST_TRANSCRIPT_DIR}"

	run "$PHYLLARY" glean
	[ "$status" -eq 5 ]
	[[ "$output" == *"failed to process"* ]]
	[[ "$output" == *"rerun 'phyllary glean'"* ]]
	[ -z "$(find "${PHYLLARY_GLEAN_STATE_DIR}" -name '*.watermark' -print -quit 2>/dev/null)" ]
}

@test "glean: failed judgment command does not advance the watermark" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1
	export PHYLLARY_GLEAN_JUDGMENT_CMD='cat >/dev/null; exit 9'
	create_test_transcripts "${PHYLLARY_TEST_TRANSCRIPT_DIR}"

	run "$PHYLLARY" glean
	[ "$status" -eq 5 ]
	[[ "$output" == *"failed to process"* ]]
	[[ "$output" == *"rerun 'phyllary glean'"* ]]
	[ -z "$(find "${PHYLLARY_GLEAN_STATE_DIR}" -name '*.watermark' -print -quit 2>/dev/null)" ]
}

@test "glean: whitespace-only judgment separator lines are ignored" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1
	export PHYLLARY_GLEAN_JUDGMENT_CMD='cat >/dev/null; printf "  \n{\"type\":\"none\",\"reason\":\"test\"}\n\t\n"'
	create_test_transcripts "${PHYLLARY_TEST_TRANSCRIPT_DIR}"

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	[ -n "$(find "${PHYLLARY_GLEAN_STATE_DIR}" -name '*.watermark' -print -quit 2>/dev/null)" ]
}

@test "glean: default transcript scope is the current project slug, not the whole archive" {
	local tmpdir projects slug wanted other
	tmpdir=$(mktemp -d)
	projects="${BATS_TEST_TMPDIR}/projects-root"
	mkdir -p "$projects"
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary
	slug=$(printf '%s' "$(pwd -P)" | tr '/' '-')
	wanted="$projects/$slug"
	other="$projects/-other-project"
	mkdir -p "$wanted" "$other"
	write_transcript "$wanted/session.jsonl" '{"type":"mode","sessionId":"wanted"}'
	write_transcript "$other/session.jsonl" '{"type":"mode","sessionId":"other"}'

	unset PHYLLARY_GLEAN_TRANSCRIPT_DIR
	export PHYLLARY_GLEAN_PROJECTS_ROOT="$projects"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
	[[ "$output" == *"glean: scanning 1 transcript file(s)"* ]]
	[[ "$output" == *"harvesting $wanted/session.jsonl"* ]]
	[[ "$output" != *"$other/session.jsonl"* ]]
}

@test "glean: partial candidate filing is idempotent across retry" {
	local tmpdir fakebin logdir transcript_dir
	tmpdir=$(mktemp -d)
	fakebin="${BATS_TEST_TMPDIR}/fakebin"
	logdir="${BATS_TEST_TMPDIR}/fake-bd"
	mkdir -p "$fakebin" "$logdir"
	cat >"$fakebin/bd" <<'FAKEBD'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_BD_STATE:?}"
mkdir -p "$state/captures"
case "$1" in
  config) exit 0 ;;
  search)
    [ "${FAIL_BD_SEARCH:-0}" = 1 ] && exit 9
    if [ "$2" != "--desc-contains" ]; then
      # Real bd searches titles by default; the idempotency key lives in the body.
      printf '[]\n'
      exit 0
    fi
    key="$3"
    for f in "$state"/captures/*; do
      [ -f "$f" ] || continue
      if grep -qF "$key" "$f"; then
        id=$(basename "$f")
        printf '[{"id":"%s"}]\n' "$id"
        exit 0
      fi
    done
    printf '[]\n'
    ;;
  create)
    title="$2" body_file=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) body_file="$2"; shift ;;
      esac
      shift || true
    done
    if [ "$title" = "candidate two" ]; then
      echo fail-second >>"$state/create.log"
      exit 1
    fi
    id="fake-$(wc -l <"$state/create.log" 2>/dev/null || printf 0)"
    echo "$title" >>"$state/create.log"
    cat "$body_file" >"$state/captures/$id"
    printf '%s\n' "$id"
    ;;
  show)
    printf '[{"id":"%s"}]\n' "$2"
    ;;
  *) exit 0 ;;
esac
FAKEBD
	chmod +x "$fakebin/bd"

	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary
	transcript_dir="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="$transcript_dir"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	export PHYLLARY_GLEAN_MIN_CHUNK_LINES=1
	export FAKE_BD_STATE="$logdir"
	export PATH="$fakebin:$PATH"
	export PHYLLARY_GLEAN_JUDGMENT_CMD='cat >/dev/null; echo "{\"type\":\"impediment\",\"title\":\"candidate one\",\"body\":\"body one\"}"; echo "{\"type\":\"impediment\",\"title\":\"candidate two\",\"body\":\"body two\"}"'
	create_test_transcripts "$transcript_dir"

	run "$PHYLLARY" glean
	[ "$status" -eq 5 ]
	[ -z "$(find "${PHYLLARY_GLEAN_STATE_DIR}" -name '*.watermark' -print -quit 2>/dev/null)" ]
	[ "$(grep -c '^candidate one$' "$logdir/create.log")" -eq 1 ]

	# Retry output may differ; chunk position, not model wording, is the idempotency key.
	export PHYLLARY_GLEAN_JUDGMENT_CMD='cat >/dev/null; echo "{\"type\":\"impediment\",\"title\":\"candidate one\",\"body\":\"reworded body\"}"; echo "{\"type\":\"impediment\",\"title\":\"candidate two\",\"body\":\"body two\"}"'
	run "$PHYLLARY" glean
	[ "$status" -eq 5 ]
	[ "$(grep -c '^candidate one$' "$logdir/create.log")" -eq 1 ]

	# A failed idempotency lookup is operational failure, never permission to duplicate.
	export FAIL_BD_SEARCH=1
	run "$PHYLLARY" glean
	[ "$status" -eq 5 ]
	[[ "$output" == *"capture lookup failed"* ]]
	[ "$(grep -c '^candidate one$' "$logdir/create.log")" -eq 1 ]
}

@test "glean: state directory created at ~/.local/state/phyllary/ by default" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	# Don't override state dir - use default
	unset PHYLLARY_GLEAN_STATE_DIR
	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"

	run "$PHYLLARY" glean
	[ "$status" -eq 0 ]
}

@test "glean: unavailable state directory is a prescriptive operational failure" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_STATE_DIR=/dev/null/phyllary-glean
	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	run "$PHYLLARY" glean
	[ "$status" -eq 5 ]
	[[ "$output" == *"state path unavailable"* ]]
	[[ "$output" == *"rerun 'phyllary glean'"* ]]
	[[ "$output" != *"Traceback"* ]]
}

@test "glean: --async starts a background harvest and returns immediately" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	export PHYLLARY_GLEAN_TRANSCRIPT_DIR="${PHYLLARY_TEST_TRANSCRIPT_DIR}"
	export PHYLLARY_GLEAN_STATE_DIR="${PHYLLARY_GLEAN_STATE_DIR}"
	run "$PHYLLARY" glean --async
	[ "$status" -eq 0 ]
	[ "$output" = "glean: async harvest started (log: ${PHYLLARY_GLEAN_STATE_DIR}/glean.log)" ]
}

@test "glean: --explain prints verb documentation" {
	run "$PHYLLARY" --explain glean
	[ "$status" -eq 0 ]
	[[ "$output" == *"watermark sweep"* ]]
	[[ "$output" == *"phyllary glean"* ]]
}

@test "glean: unknown sub-verb under glean fails" {
	local tmpdir
	tmpdir=$(mktemp -d)
	cd "$tmpdir"
	git init -q
	git config user.email "test@test"
	git config user.name "Test"
	printf 'backlog: bd\n' >.phyllary

	run "$PHYLLARY" glean unknown
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument 'unknown'"* ]]
}