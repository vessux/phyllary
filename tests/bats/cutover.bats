#!/usr/bin/env bats
# cutover.bats — phyllary cutover + local docs (dotfiles-dft.8)

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "repo commits the Phyllary marker and Project-gate configuration" {
	cd "$REPO_ROOT"
	[ "$(cat .phyllary)" = $'backlog: bd\nproject-gate: phyllary/project-gate.json' ]
}

@test "GitHub validation invokes the project-owned adapter, not Phyllary reconciliation" {
	cd "$REPO_ROOT"
	grep -q 'phyllary/project-gate run' .github/workflows/delivery-gate.yml
	! grep -q 'bin/phyllary backlog gate' .github/workflows/delivery-gate.yml
}

@test "CLAUDE layer names Phyllary, not storage backends" {
	cd "$REPO_ROOT"
	[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
	grep -q 'phyllary' AGENTS.md
	run grep -nEi '(^|[^[:alnum:]_])(bd|beads?|github|gh)([^[:alnum:]_]|$)' AGENTS.md
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
}

@test "zshenv no longer advertises nextdelivery" {
	cd "$REPO_ROOT"
	run grep -n 'nextdelivery' zsh/.zshenv
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
}

@test "phyllary repo-meta stays out of git and stow" {
	cd "$REPO_ROOT"
	git check-ignore -q .worktrees/example
	grep -qxF '^\.phyllary$' .stow-local-ignore
}

@test "Python bytecode and cache artifacts stay out of git" {
	cd "$REPO_ROOT"
	git check-ignore -q phyllary/src/phyllary/__pycache__/cli.cpython-311.pyc
	git check-ignore -q phyllary/src/phyllary/cli.pyc
	git check-ignore -q phyllary/src/phyllary/cli.pyo
	git check-ignore -q phyllary/src/phyllary/_native.pyd
}

@test "operator issue-tracker doc no longer calls this repo private-tier" {
	cd "$REPO_ROOT"
	run grep -n 'private tier' docs/agents/issue-tracker.md
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
	grep -q 'Phyllary-backed backlog' docs/agents/issue-tracker.md
}

@test "nextdelivery is only a Phyllary compatibility shim" {
	cd "$REPO_ROOT"
	grep -q "phyllary backlog next" bin/nextdelivery
	grep -q "phyllary doctor" bin/nextdelivery
	run grep -n 'umbel adopt\|repo-visibility\|bd list\|gh issue' bin/nextdelivery
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
}

@test "old-generation umbel bundles still resolve" {
	command -v umbel >/dev/null 2>&1 || skip "umbel not installed"
	cd "$REPO_ROOT"
	run env UMBEL_ARTIFACTS_DIR="$REPO_ROOT/umbel" umbel show discovery
	[ "$status" -eq 0 ]
	[[ "$output" == *'name: discovery'* ]]
	run env UMBEL_ARTIFACTS_DIR="$REPO_ROOT/umbel" umbel show delivery-superpowers
	[ "$status" -eq 0 ]
	[[ "$output" == *'name: delivery-superpowers'* ]]
}
