# How rex-fzf-links works

This page explains what happens when you pick a link, and why the plugin is built this way. You don't need it to use the plugin; see the [README](../README.md) for that.

## How opening works

`pick_link` runs in the Rex config on the client. It reads the end of the pane's text, finds the links, and builds every link's open and copy command **on the client** before the picker opens. It saves them in a private temp dir (`job.json`). A pick only selects one of these commands, so nothing the picker or the remote host prints is ever executed. What happens next depends on where the pane is:

```
 pick_link (Rex config, client)
   items <- links in the pane's text (newest max_items)
   job   <- open and copy command for every item, built on the client
   |
   +-- local pane
   |     picker (on the client)
   |       pick N -> rex do bin/act.lua job=... action=open|copy n=N ; exit
   |       esc    -> remove the job ; exit
   |     nothing else runs
   |
   +-- remote pane
         endpoint <- the Rex app's tunnel socket to the host (ssh hosts)
                     or the host's label (other endpoint kinds)
         picker (on the host)
           pick N -> set its title to "rfl:<token>:open|copy:<N>" ; exit
           esc    -> exit
         bin/dispatch.lua (client, detached), connected to the host's server:
           title with the token from the picker's pane -> run command N ; stop
           the picker's program exited                 -> stop
```

- **Local panes:** the picker runs on the client, so it runs the chosen command itself, through `bin/act.lua`. No other process is started. If the command fails, the picker shows the error until you press a key.
- **Panes on remote hosts:** the picker runs on the host and can't reach your browser or clipboard. It sets its own terminal title to a one-line message with a random token, made for that picker only. The dispatcher sees the title as a `terminal.title_changed` event from the picker's pane, checks the pane and the token, runs the command, and exits. When the picker exits with no message (`esc`), the dispatcher exits too. It also gives up after 30 minutes.
- Either way the picker pane closes when the picker exits, and focus returns to your pane.
- No process runs while the picker is closed.

### Reaching the remote Rex server

For every ssh host it is connected to, the macOS Rex app runs a helper (`rex __internal ssh-tunnel ssh://HOST`) whose ssh child forwards a local unix socket to the host's Rex server. The plugin finds that socket (from the helper's process and its `-L` argument, matching `rex hosts` first and then the active tunnel that owns the pane's session) and connects the dispatcher to it, so a pick needs no new ssh connection. Hosts with other endpoint kinds are reached directly, the way `rex -S <host-label>` does.

### The scrolling list

fzf can't report which rows it has scrolled to: `FZF_POS` and `{n}` are positions in the whole list. To keep the `1`-`9` numbers on the rows you see, the picker gives fzf only the rows that fit (`share/filter.awk`) and moves that window itself when the highlight goes past an edge, reloading the list with new numbers. The number of rows that fit is worked out from `FZF_LINES` and the picker's layout.

## Why this design

The picker over a remote pane has to tell the client which link was chosen. These ways were tried (with a macOS client and an ssh host) before choosing the title message over the app's tunnel:

| Way | Why not |
|---|---|
| the picker's exit code, read by a dispatcher over a direct `rex -S` connection | the direct connection failed 2 of 3 times behind an ssh ControlMaster, and every time when the detached process found a different `ssh`; the exit code also limited the list to 60 links |
| the clipboard, set by the picker through an escape sequence | works, but replaces what you had copied |
| the macOS window name (it shows the pane's title) | works, but depends on the app's window title format, and the message shows in the window name |
| a Rex key mode that waits for a key from the picker | works, but Rex shows its key-sequence hint popup on every pick |
| the pane's process info (`terminal.process_changed`) | carries only the pane's starting shell, not a renamed process |
| a separate ssh forward to the host's Rex socket, kept running | works, but needs per-machine setup; the app already keeps one |

Local panes need none of this: the picker already runs on the client.
