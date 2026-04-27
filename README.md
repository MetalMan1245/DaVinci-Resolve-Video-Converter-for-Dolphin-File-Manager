# DaVinci Resolve Video Converter for Dolphin File Manager

A small script that converts a video file to a DaVinci Resolve compatible format and container (AV1 with flac audio in an mkv container) with support for passthrough if video or audio is already compatible, and batch conversion.  Includes a .desktop file for context menu integration with KDE Dolphin File Manager.

## Dependencies

1. `bash`
2. `ffmpeg`
3. `ffprobe` (Comes with ffmpeg)
4. `zenity`

## Install

Double click `resolveconverter-installer.desktop` and run as a program (you can also run `ffmpeg-install_remote-resolve.sh` by itself or `install_uninstall-resolve.sh` in if you installed the entire repo)

For a manual install:
1. Put `ResolveConvert.sh` in `~/.local/bin`
2. Put `VideoConverterResolve.desktop` `~/.local/share/kio/servicemenus/`.
3. `chmod +x ~/.local/bin/ResolveConvert.sh`
4. `chmod +x ~/.local/share/kio/servicemenus/VideoConverterResolve.desktop`
5. Edit `.desktop` file if you want the script elsewhere.
6. Feel free to change any part of this to suit your needs.

## Use

Right-click file in Dolphin -> Convert for Resolve.  You will be prompted to choose Auto (recommended), force VAAPI (fast), or force CPU (SVT-AV1 quality).  Auto will choose VAAPI if it is available and fall back to CPU encoding if not.

You may also run `~/.local/bin/ResolveConvert.sh /path/to/your/file` to run the script manually without Dolphin.

## Notes

For a more general purpose converter see `https://github.com/MetalMan1245/dolphin-context-convert-davinci` (the reason this isn't forked from that is because I got frustrated working with someone else's code and bolting on a different tool to an already existing thing that was messy to begin with)  Eventually I will remove the Resolve features from that so that they are located here, and that is just an improvement to the original project it is forked from `https://github.com/NuVanDibe/dolphin-context-convert`

Video will be passed through if it is already AV1, audio will be passed through if it is already flac, and `originalfilename_originalextension_converted.mkv` will be generated in the same directory as your file.

Batch file conversion is possible, though untested when used on a full folder, only tested on selected files.

Multi stream audio is supported, all streams will either be converted to flac or passed through if they are already flac.

Your original file will never be overwritten, however subsequent conversions of the same file may cause overwrites of the previous conversion.

## Upcoming Features
Major:

`Add passthrough for other already resolve compatible codecs (DNxHR, pcm, etc.)`

## Disclaimers

THIS IS VIBE CODED.  I am not a real programmer and as such AI was used to create this, therefore I do not promise quality, repeatability, or robustness.

That said I use this script myself to convert video from cameras as part of footage ingestion (maybe one day Blackmagic will fix the Linux build and all of this will be unnecessary) and if you think you can do better, feel free to message me here or on my discord `metalman1245` or fork if you would rather create your own project.  Though I personally hate fragmentation, so I would much rather you just get in contact with me and I will add you to this repo so you can push changes yourself.
