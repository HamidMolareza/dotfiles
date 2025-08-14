#!/bin/bash

# TODO: validate commands: Ensure necessary commands are exists.
if ! command -v xclip &>/dev/null; then
    zenity --error --text="xclip could not be found. Please install it to use this script."
    exit 1
fi

# Check for no arguments
if [ "$#" -eq 0 ]; then
    zenity --error --text="No files or directories specified."
    exit 1
fi

# TODO: Consider single or multi select file/folders
if [ "$#" -eq 1 ]; then
    notify-send "Hello!" "More than one file/folders selected."
else
    notify-send "Hello!" "Only one file/folder selected."
fi

# Loop through the selected files/folders and append their paths to the tempfile
for uri in "$@"; do
    # TODO: User may select file or folder or even other types
    if [ -d "$uri" ]; then
        if zenity --question --text="Do you want to do operation recursive?"; then
            notify-send "Hello!" "YES!"
        else
            notify-send "Hello!" "NO!"
        fi
    fi
done

# TODO: Say operation was successful if is need:
notify-send "Install Packages" "NuGet packages installed successfully."

# TODO: save to $HOME/.local/share/nautilus/scripts

# TODO: Make script executable
# chmod +x -R $HOME/.local/share/nautilus/scripts
