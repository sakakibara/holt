//! Shell integration snippets for `holt init`: the `h`/`hi` navigation
//! functions, one flavor per supported shell. `h` shells out to `holt path`
//! and cds to whatever it printed, since a child process can't change its
//! parent shell's directory; `hi` pipes `holt list` through fzf first.

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
    \\function hi
    \\    set -l proj (holt list | fzf)
    \\    if test -z "$proj"
    \\        return 1
    \\    end
    \\    set -l dir (holt path $proj)
    \\    and cd $dir
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
    \\hi() {
    \\    local proj
    \\    proj="$(holt list | fzf)"
    \\    if [ -z "$proj" ]; then
    \\        return 1
    \\    fi
    \\    local dir
    \\    dir="$(holt path "$proj")"
    \\    if [ $? -eq 0 ]; then
    \\        cd "$dir" || return 1
    \\    fi
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
    \\function hi {
    \\    $proj = holt list | fzf
    \\    if ([string]::IsNullOrEmpty($proj)) {
    \\        return
    \\    }
    \\    $dir = holt path $proj
    \\    if ($LASTEXITCODE -eq 0) {
    \\        Set-Location $dir
    \\    }
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
