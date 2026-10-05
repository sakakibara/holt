//! Shell integration snippets for `holt init`: the `h`/`hi`/`hir` navigation
//! functions, one flavor per supported shell. `h` shells out to `holt path`
//! and cds to whatever it printed, since a child process can't change its
//! parent shell's directory; `hi` picks a line of `holt list` with fzf first;
//! `hir` picks a line of `holt list --repos` and cds to it under code_root.
//! Each reads holt's whole list before fzf takes the terminal, so a failure
//! or an empty list is reported where it can be seen. fzf opens below the
//! prompt with a preview listing the picked directory; it runs the preview
//! in `sh`, or on PowerShell in PowerShell itself.

const std = @import("std");
const testing = std.testing;

pub const Shell = enum { fish, zsh, bash, powershell };

pub fn parse(name: []const u8) ?Shell {
    return std.meta.stringToEnum(Shell, name);
}

pub fn snippet(shell: Shell) []const u8 {
    return switch (shell) {
        .fish => fish_snippet,
        .zsh => zsh_snippet,
        .bash => bash_snippet,
        .powershell => powershell_snippet,
    };
}

const fish_snippet =
    \\function h
    \\    set -l dir (holt path $argv)
    \\    and cd $dir
    \\end
    \\
    \\function __holt_fzf
    \\    SHELL=sh fzf --height=45% --layout=reverse --border=sharp --info=inline --cycle --keep-right --tabstop=1 --bind=ctrl-z:ignore,btab:up,tab:down --preview-window=down,30%,sharp --preview=$argv[1]
    \\end
    \\
    \\function hi
    \\    set -l projs (holt list)
    \\    or return
    \\    if test (count $projs) -eq 0
    \\        echo "hi: no projects to pick from" >&2
    \\        return 1
    \\    end
    \\    set -l proj (printf '%s\n' $projs | __holt_fzf 'ls -Cp "$(holt path {})"')
    \\    if test -z "$proj"
    \\        return 1
    \\    end
    \\    set -l dir (holt path $proj)
    \\    and cd $dir
    \\end
    \\
    \\function hir
    \\    set -l root (holt path --root code)
    \\    or return
    \\    set -l keys (holt list --repos)
    \\    or return
    \\    if test (count $keys) -eq 0
    \\        echo "hir: no clones to pick from" >&2
    \\        return 1
    \\    end
    \\    set -l key (printf '%s\n' $keys | __holt_fzf 'ls -Cp "$(holt path --root code)"/{}')
    \\    if test -z "$key"
    \\        return 1
    \\    end
    \\    cd "$root/$key"
    \\end
    \\
    \\# Tab-completion. `holt __complete` prints a directive line then one
    \\# candidate per line as "value<TAB>description"; fish's `-a` splits on
    \\# that tab natively, so the raw lines pass straight into it. Org
    \\# candidates end in "/" so fish already omits the trailing space.
    \\function __holt_complete
    \\    holt __complete (commandline -opc)[2..-1] (commandline -ct) | tail -n +2
    \\end
    \\complete -c holt -f -a '(__holt_complete)'
    \\complete -c h -f -a '(holt __complete path (commandline -ct) | tail -n +2)'
    \\
;

// The POSIX `h`/`hi` functions bash and zsh share; each appends its own
// (non-portable) completion registration below.
const posix_hhi =
    \\h() {
    \\    local dir
    \\    dir="$(holt path "$1")"
    \\    if [ $? -eq 0 ]; then
    \\        cd "$dir" || return 1
    \\    fi
    \\}
    \\
    \\__holt_fzf() {
    \\    SHELL=sh fzf --height=45% --layout=reverse --border=sharp --info=inline --cycle --keep-right --tabstop=1 --bind=ctrl-z:ignore,btab:up,tab:down --preview-window=down,30%,sharp --preview="$1"
    \\}
    \\
    \\hi() {
    \\    local projs proj dir
    \\    projs="$(holt list)" || return
    \\    if [ -z "$projs" ]; then
    \\        echo "hi: no projects to pick from" >&2
    \\        return 1
    \\    fi
    \\    proj="$(printf '%s\n' "$projs" | __holt_fzf 'ls -Cp "$(holt path {})"')"
    \\    if [ -z "$proj" ]; then
    \\        return 1
    \\    fi
    \\    dir="$(holt path "$proj")"
    \\    if [ $? -eq 0 ]; then
    \\        cd "$dir" || return 1
    \\    fi
    \\}
    \\
    \\hir() {
    \\    local root keys key
    \\    root="$(holt path --root code)" || return
    \\    keys="$(holt list --repos)" || return
    \\    if [ -z "$keys" ]; then
    \\        echo "hir: no clones to pick from" >&2
    \\        return 1
    \\    fi
    \\    key="$(printf '%s\n' "$keys" | __holt_fzf 'ls -Cp "$(holt path --root code)"/{}')"
    \\    if [ -z "$key" ]; then
    \\        return 1
    \\    fi
    \\    cd "$root/$key" || return 1
    \\}
    \\
;

const bash_completion =
    \\_holt_complete() {
    \\    local cur="${COMP_WORDS[COMP_CWORD]}"
    \\    local IFS=$'\n'
    \\    local reply=($(holt __complete "${COMP_WORDS[@]:1:COMP_CWORD}"))
    \\    local directive="${reply[0]}"
    \\    reply=("${reply[@]:1}")
    \\    if [ "$directive" = "files" ]; then
    \\        COMPREPLY=($(compgen -f -- "$cur")); return
    \\    fi
    \\    [ "$directive" = "nospace" ] && compopt -o nospace 2>/dev/null
    \\    COMPREPLY=()
    \\    local line val
    \\    for line in "${reply[@]}"; do
    \\        val="${line%%$'\t'*}"                 # drop the description at the tab
    \\        COMPREPLY+=("$(printf '%q' "$val")")  # quote so a space is one word
    \\    done
    \\}
    \\complete -F _holt_complete holt
    \\_h_complete() {
    \\    local IFS=$'\n'
    \\    local reply=($(holt __complete path "${COMP_WORDS[COMP_CWORD]}"))
    \\    reply=("${reply[@]:1}")
    \\    COMPREPLY=()
    \\    local line val
    \\    for line in "${reply[@]}"; do
    \\        val="${line%%$'\t'*}"
    \\        COMPREPLY+=("$(printf '%q' "$val")")
    \\    done
    \\}
    \\complete -F _h_complete h
    \\
;

const zsh_completion =
    \\_holt_complete() {
    \\    local -a lines values descs
    \\    lines=("${(@f)$(holt __complete ${words[2,$CURRENT]})}")
    \\    local directive=$lines[1]
    \\    lines=(${lines[2,-1]})
    \\    local line
    \\    for line in $lines; do
    \\        values+=("${line%%$'\t'*}")
    \\        if [[ $line == *$'\t'* ]]; then descs+=("${line#*$'\t'}"); else descs+=("${line%%$'\t'*}"); fi
    \\    done
    \\    if [[ $directive == files ]]; then
    \\        _files
    \\    elif [[ $directive == nospace ]]; then
    \\        compadd -S '' -d descs -- $values
    \\    else
    \\        compadd -d descs -- $values
    \\    fi
    \\}
    \\compdef _holt_complete holt
    \\_h_complete() {
    \\    local -a lines values descs
    \\    lines=("${(@f)$(holt __complete path ${words[CURRENT]})}")
    \\    lines=(${lines[2,-1]})
    \\    local line
    \\    for line in $lines; do
    \\        values+=("${line%%$'\t'*}")
    \\        if [[ $line == *$'\t'* ]]; then descs+=("${line#*$'\t'}"); else descs+=("${line%%$'\t'*}"); fi
    \\    done
    \\    compadd -d descs -- $values
    \\}
    \\compdef _h_complete h
    \\
;

const bash_snippet = posix_hhi ++ bash_completion;
const zsh_snippet = posix_hhi ++ zsh_completion;

const powershell_snippet =
    \\Remove-Item -Path Alias:h -Force -ErrorAction SilentlyContinue
    \\function h {
    \\    param([string]$Query)
    \\    $dir = holt path $Query
    \\    if ($LASTEXITCODE -eq 0) {
    \\        Set-Location $dir
    \\    }
    \\}
    \\
    \\function __holt_fzf {
    \\    param([string]$Preview)
    \\    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    \\    $input | fzf '--height=45%' '--layout=reverse' '--border=sharp' '--info=inline' '--cycle' '--keep-right' '--tabstop=1' '--bind=ctrl-z:ignore,btab:up,tab:down' '--preview-window=down,30%,sharp' "--with-shell=$shell -NoLogo -NoProfile -NonInteractive -Command" "--preview=$Preview"
    \\}
    \\
    \\function hi {
    \\    $projs = @(holt list)
    \\    if ($LASTEXITCODE -ne 0) {
    \\        return
    \\    }
    \\    if ($projs.Count -eq 0) {
    \\        [Console]::Error.WriteLine('hi: no projects to pick from')
    \\        $global:LASTEXITCODE = 1
    \\        return
    \\    }
    \\    $proj = $projs | __holt_fzf 'Get-ChildItem -Name -LiteralPath (holt path {})'
    \\    if ([string]::IsNullOrEmpty($proj)) {
    \\        return
    \\    }
    \\    $dir = holt path $proj
    \\    if ($LASTEXITCODE -eq 0) {
    \\        Set-Location $dir
    \\    }
    \\}
    \\
    \\function hir {
    \\    $root = holt path --root code
    \\    if ($LASTEXITCODE -ne 0) {
    \\        return
    \\    }
    \\    $keys = @(holt list --repos)
    \\    if ($LASTEXITCODE -ne 0) {
    \\        return
    \\    }
    \\    if ($keys.Count -eq 0) {
    \\        [Console]::Error.WriteLine('hir: no clones to pick from')
    \\        $global:LASTEXITCODE = 1
    \\        return
    \\    }
    \\    $key = $keys | __holt_fzf 'Get-ChildItem -Name -LiteralPath (Join-Path (holt path --root code) {})'
    \\    if ([string]::IsNullOrEmpty($key)) {
    \\        return
    \\    }
    \\    Set-Location (Join-Path $root $key)
    \\}
    \\
    \\Register-ArgumentCompleter -Native -CommandName holt -ScriptBlock {
    \\    param($wordToComplete, $commandAst, $cursorPosition)
    \\    $tokens = @($commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { "$_" })
    \\    & holt __complete @tokens $wordToComplete | Select-Object -Skip 1 | ForEach-Object {
    \\        $parts = $_ -split "`t", 2
    \\        $val = $parts[0]
    \\        $desc = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
    \\        [System.Management.Automation.CompletionResult]::new($val, $val, 'ParameterValue', $desc)
    \\    }
    \\}
    \\
    \\Register-ArgumentCompleter -CommandName h -ParameterName Query -ScriptBlock {
    \\    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    \\    & holt __complete path $wordToComplete | Select-Object -Skip 1 | ForEach-Object {
    \\        $parts = $_ -split "`t", 2
    \\        $val = $parts[0]
    \\        $desc = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
    \\        [System.Management.Automation.CompletionResult]::new($val, $val, 'ParameterValue', $desc)
    \\    }
    \\}
    \\
;

test "parse: recognizes every supported shell name, rejects anything else" {
    try testing.expectEqual(Shell.fish, parse("fish").?);
    try testing.expectEqual(Shell.zsh, parse("zsh").?);
    try testing.expectEqual(Shell.bash, parse("bash").?);
    try testing.expectEqual(Shell.powershell, parse("powershell").?);
    try testing.expect(parse("csh") == null);
    try testing.expect(parse("") == null);
}

test "snippet: every shell defines h and hi and calls holt path" {
    inline for (.{ Shell.fish, Shell.zsh, Shell.bash, Shell.powershell }) |sh| {
        const s = snippet(sh);
        try testing.expect(std.mem.indexOf(u8, s, "function h ") != null or std.mem.indexOf(u8, s, "function h\n") != null or std.mem.indexOf(u8, s, "h() {") != null);
        try testing.expect(std.mem.indexOf(u8, s, "function hi ") != null or std.mem.indexOf(u8, s, "function hi\n") != null or std.mem.indexOf(u8, s, "hi() {") != null);
        try testing.expect(std.mem.indexOf(u8, s, "holt path") != null);
        try testing.expect(std.mem.indexOf(u8, s, "holt list") != null);
        try testing.expect(std.mem.indexOf(u8, s, "fzf") != null);
    }
}

test "snippet: every shell wires holt __complete for tab completion" {
    inline for (.{ Shell.fish, Shell.zsh, Shell.bash, Shell.powershell }) |sh| {
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "holt __complete") != null);
    }
}

test "snippet: fish uses function/end, bash and zsh use POSIX name(), powershell uses function{}" {
    try testing.expect(std.mem.indexOf(u8, snippet(.fish), "function h\n") != null);
    try testing.expect(std.mem.indexOf(u8, snippet(.fish), "\nend") != null);
    try testing.expect(std.mem.indexOf(u8, snippet(.bash), "h() {") != null);
    try testing.expect(std.mem.indexOf(u8, snippet(.zsh), "h() {") != null);
    try testing.expect(std.mem.indexOf(u8, snippet(.powershell), "function h {") != null);
}

test "snippet: powershell registers a completer for h, not just holt" {
    try testing.expect(std.mem.indexOf(u8, snippet(.powershell), "-CommandName h -ParameterName Query") != null);
}

test "snippet: powershell splits the description off the tab for both completers" {
    const s = snippet(.powershell);
    try testing.expect(std.mem.indexOf(u8, s, "-split \"`t\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "'ParameterValue', $desc") != null);
}

test "snippet: zsh renders candidate descriptions via compadd -d" {
    try testing.expect(std.mem.indexOf(u8, snippet(.zsh), "compadd -d") != null);
}

test "snippet: bash strips the description at the tab and quotes the value" {
    const s = snippet(.bash);
    try testing.expect(std.mem.indexOf(u8, s, "%%$'\\t'") != null);
    try testing.expect(std.mem.indexOf(u8, s, "printf '%q'") != null);
}

test "snippet: every shell defines hir wired to `holt list --repos` and fzf" {
    inline for (.{ Shell.fish, Shell.zsh, Shell.bash, Shell.powershell }) |sh| {
        const s = snippet(sh);
        try testing.expect(std.mem.indexOf(u8, s, "hir") != null);
        try testing.expect(std.mem.indexOf(u8, s, "holt list --repos") != null);
    }
}

test "snippet: hir joins its relative key onto code_root from the path accessor, not a parsed report" {
    inline for (.{ Shell.fish, Shell.zsh, Shell.bash, Shell.powershell }) |sh| {
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "holt path --root code") != null);
        // Parsing `holt config` would tie navigation to a human-facing
        // report's wording and to its paths staying uncontracted.
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "holt config") == null);
    }
}

test "snippet: hir is argless and gets no completion registration" {
    // Only `h` is registered for completion; hir/hi are fzf-driven.
    try testing.expect(std.mem.indexOf(u8, snippet(.fish), "complete -c hir") == null);
    try testing.expect(std.mem.indexOf(u8, snippet(.bash), "complete -F _hir") == null);
    try testing.expect(std.mem.indexOf(u8, snippet(.zsh), "compdef _hir") == null);
    try testing.expect(std.mem.indexOf(u8, snippet(.powershell), "-CommandName hir") == null);
}

const all_shells = .{ Shell.fish, Shell.zsh, Shell.bash, Shell.powershell };

test "snippet: hi and hir read holt's list whole before fzf starts, and return holt's failure" {
    try testing.expect(std.mem.indexOf(u8, snippet(.fish), "    set -l projs (holt list)\n    or return\n") != null);
    try testing.expect(std.mem.indexOf(u8, snippet(.fish), "    set -l keys (holt list --repos)\n    or return\n") != null);
    inline for (.{ Shell.zsh, Shell.bash }) |sh| {
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "    projs=\"$(holt list)\" || return\n") != null);
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "    keys=\"$(holt list --repos)\" || return\n") != null);
    }
    try testing.expect(std.mem.indexOf(u8, snippet(.powershell), "    $projs = @(holt list)\n    if ($LASTEXITCODE -ne 0) {\n") != null);
    try testing.expect(std.mem.indexOf(u8, snippet(.powershell), "    $keys = @(holt list --repos)\n    if ($LASTEXITCODE -ne 0) {\n") != null);
    inline for (all_shells) |sh| {
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "holt list | fzf") == null);
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "holt list --repos | fzf") == null);
    }
}

test "snippet: hi and hir say why on stderr when there is nothing to pick" {
    inline for (all_shells) |sh| {
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "hi: no projects to pick from") != null);
        try testing.expect(std.mem.indexOf(u8, snippet(sh), "hir: no clones to pick from") != null);
    }
    try testing.expect(std.mem.count(u8, snippet(.fish), "to pick from\" >&2\n        return 1\n") == 2);
    try testing.expect(std.mem.count(u8, snippet(.bash), "to pick from\" >&2\n        return 1\n") == 2);
    try testing.expect(std.mem.count(u8, snippet(.powershell), "to pick from')\n        $global:LASTEXITCODE = 1\n        return\n") == 2);
}

test "snippet: fzf opens below the prompt with zoxide's look and keys, matching fuzzily" {
    const opts = [_][]const u8{ "--height=45%", "--layout=reverse", "--border=sharp", "--info=inline", "--cycle", "--keep-right", "--tabstop=1", "--bind=ctrl-z:ignore,btab:up,tab:down", "--preview-window=down,30%,sharp" };
    inline for (all_shells) |sh| {
        const s = snippet(sh);
        for (opts) |o| if (std.mem.indexOf(u8, s, o) == null) {
            std.debug.print("{t} is missing {s}\n", .{ sh, o });
            return error.TestUnexpectedResult;
        };
        try testing.expect(std.mem.indexOf(u8, s, "--exact") == null);
        try testing.expect(std.mem.indexOf(u8, s, "--no-sort") == null);
    }
}

test "snippet: the preview lists the directory a line names, in a shell each snippet picks" {
    inline for (.{ Shell.fish, Shell.zsh, Shell.bash }) |sh| {
        const s = snippet(sh);
        try testing.expect(std.mem.indexOf(u8, s, "SHELL=sh fzf ") != null);
        try testing.expect(std.mem.indexOf(u8, s, "'ls -Cp \"$(holt path {})\"'") != null);
        try testing.expect(std.mem.indexOf(u8, s, "'ls -Cp \"$(holt path --root code)\"/{}'") != null);
    }
    const ps = snippet(.powershell);
    try testing.expect(std.mem.indexOf(u8, ps, "--with-shell=") != null);
    try testing.expect(std.mem.indexOf(u8, ps, "'Get-ChildItem -Name -LiteralPath (holt path {})'") != null);
    try testing.expect(std.mem.indexOf(u8, ps, "'Get-ChildItem -Name -LiteralPath (Join-Path (holt path --root code) {})'") != null);
}
