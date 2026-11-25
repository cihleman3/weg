# weg

Deletes files and folders on Windows for good, even when a process still holds them:

```
$ weg 3-patterns
killed node.exe (PID 7232)
removed C:\Users\me\talk\3-patterns
```

- No recycle bin and no questions. Use `--dry-run` to see first what would happen.
- If a plain delete fails, `weg` looks for the processes that lock the target and kills them: processes whose working directory is inside it, and processes that have a file in it open. This needs no administrator rights.
- Junctions and symlinks inside a folder are removed as links. Their targets stay untouched.
- Paths longer than 260 characters work.
- `weg` refuses drive roots, `C:\Windows`, the Program Files folders, `C:\ProgramData` and your user folder, also as part of a larger folder.
- The shell `weg` was started from is never killed. If it blocks the target, `weg` tells you to leave the folder first.

## Installation

Requirements: Windows 10 or 11. Windows PowerShell 5.1 comes with Windows. Git Bash is optional.

### Quickest: one command in PowerShell

```powershell
$d = "$env:TEMP\weg"; Invoke-WebRequest https://github.com/cihleman3/weg/archive/refs/heads/master.zip -OutFile "$d.zip" -UseBasicParsing; Expand-Archive "$d.zip" $d -Force; powershell -ExecutionPolicy Bypass -File "$d\weg-master\install.ps1"; Remove-Item "$d.zip", $d -Recurse -Force
```

This downloads the repository as a ZIP, installs `weg` and removes the download again. Then open a new terminal.

### From a clone or a downloaded ZIP

1. Get this repository: `git clone` it, or download it as a ZIP from GitHub and unpack it.
2. In that folder:

   ```sh
   powershell -ExecutionPolicy Bypass -File .\install.ps1   # PowerShell or cmd
   bash install.sh                                          # Git Bash
   ```

3. Open a new terminal.

### Where it goes

The install script copies `weg.ps1` into `~/.local/share/weg` and the launchers into `~/.local/bin`: `weg` for Git Bash, `weg.cmd` for PowerShell and cmd. If `~/.local/bin` is not on your PATH yet, the script adds it to your user PATH.

To update, run the one-line command again, or pull or download the new version and run the install script again. To uninstall, delete `~/.local/share/weg`, `~/.local/bin/weg` and `~/.local/bin/weg.cmd`.

## Usage

```
weg [--dry-run] <path> [<path> ...]
```

| | |
|---|---|
| `-n`, `--dry-run` | Only show which processes would be killed and what would be deleted. |
| `-h`, `--help` | Show the help. |
| `--` | End of options, for paths starting with `-`. |

Relative paths are relative to the current folder. The exit code is 0 if every target was removed, 1 otherwise, and 2 for wrong usage.

## Limits

- Processes running with administrator rights cannot be killed; `weg` reports them. Run `weg` from an administrator terminal if needed.
- Working directories of 32-bit processes are not checked. Files they have open are still found.
- In PowerShell and cmd, `weg.cmd` runs through cmd, and cmd replaces `%VARIABLE%` in the paths with its value. Delete such names from Git Bash.

## Manual tests

There are no automatic tests. After a change, check in a scratch folder:

- A folder that a process uses as working directory, and a file that a process holds open exclusively (`[IO.File]::Open($path, 'Open', 'Read', 'None')` in a second PowerShell): both processes are killed and the targets removed.
- A folder with a junction to a folder outside it: the outside folder survives.
- A path longer than 260 characters.
- From Git Bash, PowerShell and cmd, with a relative path containing spaces and `&`.
- `weg --dry-run` on `C:\`, `C:\Windows` and your user folder: all refused.
