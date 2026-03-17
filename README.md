[![Get it on Flathub](https://flathub.org/api/badge?svg&locale=en)](https://flathub.org/apps/ca.vtrlx.Telepipe)

![telepipe screenshot](telepipe.png)

# Telepipe

Run command-line apps smoothly.

## About

Telepipe is a graphical command-line shell for GNOME. Telepipe offers the ability to run command-line applications using modern text editing conventions, such as using the mouse to move your cursor when entering a command, or dragging-and-dropping text selections from the command output window back into the command entry or out to other programs.

Despite appearances, Telepipe is **not a terminal**. This means that TUI apps will not work in this app, but most text-mode command-line programs should work without issue. Instead of thinking of it as an interface to a command-line shell, you should consider Telepipe itself to be your shell. For adjusting to its peculiarities as well as making good use of certain programs, see the list of [tips and tricks](https://github.com/vtrlx/telepipe/blob/trunk/docs/Tips%20and%20Tricks.md) for using Telepipe.

Telepipe's name is a portmanteau of *teletypewriter* (or *teletype*), a device which in this context allows its user to run a command-line shell from a physical typewriter, and *pipe*, a common command-line feature on UNIX and UNIX-like systems which allows the output of one command to be used as the input of another commnand. Pipelines are an especially powerful way to leverage command-line applications for advanced text processing, and Telepipe's core feature for facilitating their use is [clipboard redirection](https://github.com/vtrlx/telepipe/blob/trunk/docs/Clipboard%20Redirection.md), which allows commands to easily read from and write to the system clipboard.

## Installing

The recommended way to install Telepipe is through [Flathub](https://flathub.org/apps/ca.vtrlx.Telepipe).

Alternatively, Telepipe can be built and installed locally from source.

## Building

Telepipe is built using Flatpak and targets version 49 of the GNOME platform. With Flatpak installed and Flathub enabled as a source, ensure the platform and SDK are installed to your system:

```sh
flatpak --user install org.gnome.Platform//49 org.gnome.Sdk//49
```

To build and install the development version of Telepipe from source, use [Flatpak Builder](https://docs.flatpak.org/en/latest/flatpak-builder.html). Clone this repository, navigate to it in a command-line shell, then run:

```sh
flatpak-builder build ca.vtrlx.Telepipe.Devel.json --user --install --force-clean
```

After installing, run Telepipe either from your system's app menu or using the command `flatpak run ca.vtrlx.Telepipe.Devel`.

## Features

**Clipboard redirection**: Commands run in Telepipe can use the current clipboard contents as their input by prefixing with `>`, they can automatically copy their output to the clipboard by prefixing with `<`, or they can do both by prefixing with `|`.

More information—including examples—is available in the [documentation page](https://github.com/vtrlx/telepipe/blob/trunk/docs/Clipboard%20Redirection.md) for clipboard redirection.

**Command prefixes**: It is possible to explicitly set text (called a "prefix") which will be prepended to all subsequent commands until deactivated. Prefixes can be used to easily access remote systems without using subshells as well as avoid straining one's hands through repetitive typing.

Detailed explanations and examples on the usage of prefixes can be found in the [documentation page](https://github.com/vtrlx/telepipe/blob/trunk/docs/Prefixes.md) for prefixes.

**Output editing:** The command output section is a full text editor. This allows you to make notes, amend output for further execution, or quickly erase sections of command output which are no longer needed. Selections from the terminal output can even be dragged-and-dropped down into the command entry for use as parameters to subsequent commands.

**Visual command history:** Each of Telepipe's tabs keeps its own history, shown as a list from a menu button to the right of the command entry (visible only when there is a command history). From here, commands may be removed from history, or be copied back into the command entry to be rerun or amended.

## Anti-Features

Telepipe is not intended to replicate existing terminal emulators; It was designed from the ground up to provide a way to interact with command-line software that works better with modern user experience conventions. Many features common to terminal emulators and command-line shells are explicitly excluded in Telepipe because they are not needed. Examples include:

- Tab completion
- Output colorizing
- Monospace text
- Job control
- Support for TUI applications (`vim`, `emacs`, `less`, `top`)
- Shell prompts (unless explicitly running an interactive shell)

## Localization

Telepipe uses [gettext](https://www.gnu.org/software/gettext) for localization. These instructions assume you have it installed on your system.

To create a message file for your desired language, execute this command in a terminal from Telepipe's root folder:

```sh
make po/<LANG>.po
```

`<LANG>` should be replaced by the two-letter language code for the language you're translating the app to, optionally followed by an underscore `_` character and a two-letter country code in ALL-CAPS i.e. `fr` for French or `fr_CA` for Canadian French.

This command creates a file in the `po/` folder named `<LANG>.po`.

Next, edit the `<LANG>.po` file and add your translated strings. I recommend using [Translation Editor](https://flathub.org/apps/org.gnome.Gtranslator) for this.

The last strings to localize are for the **ca.vtrlx.Telepipe.desktop** and **ca.vtrlx.Telepipe.Devel.desktop** files. Add new lines for the `Comment`, `Keywords`, and (if applicable) `Name` keys in all sections of both files. Be sure to keep the translated lines in alphabetical order with respect to the language codes.

Once finished, try running Telepipe in your language using the [testing instructions](https://github.com/vtrlx/telepipe?tab=readme-ov-file#building) above. If all the strings appear to have been translated, commit your finished `<LANG>.po` file to Git, push the commit to a branch under your control, and submit a pull request [on GitHub](https://github.com/vtrlx/telepipe/pulls).

### Updating a Localization

If the application is updated and the translation needs to be changed, again run this command in the project's root folder:

```sh
make po/<LANG>.po
```

This will update the given `.po` file with the new translatable strings. The updated `.po` file for your language may then be modified, committed, and put into a pull request as usual.

## License

Telepipe is free software distributed under the terms of the GNU General Public License version 3 or later. See COPYING for more information.
