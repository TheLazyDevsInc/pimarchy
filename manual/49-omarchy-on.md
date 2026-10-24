# Omarchy on...

### Apple M1/M2 chips

[Asahi Alarm](https://asahi-alarm.org/) is a version of Arch for Apple M1/M2 computers built on top of [Asahi Linux](https://asahilinux.org/). You can get Omarchy running on top of that with some effort. See [the user-driven guide](https://github.com/omarchy-mac/omarchy-mac).

### Raspberry Pi 400

This fork, Pimarchy, runs Omarchy on the Raspberry Pi 400. You build an SD card image on another computer with `pi/build-image`, flash it, and boot: the Pi grows the card's root partition, sets up its hardware, and asks for your keyboard layout, account, hostname and timezone before logging you into Hyprland. The `pi/README.md` file in the [Pimarchy repository](https://github.com/TheLazyDevsInc/pimarchy) walks through building and flashing it.

A few things work differently from a laptop or desktop. The Pi boots its own firmware instead of Limine, so there are no boot-menu snapshots, no disk encryption and no hibernation, and Suspend is hidden because the Pi can't sleep. Sound plays over HDMI, since the Pi 400 has no headphone jack. `omarchy update` also rebuilds Omarchy's own packages on the Pi from its Pimarchy checkout, which adds a minute or two when something changed.

The Pi 400 support is new and hasn't been through a full test on the hardware yet.

### Apple Virtual Machine

You can also install Omarchy inside a Parallels VM. Quite the cumbersome process, but there's [a user-driven guide](https://github.com/omacom/omarchy/discussions/452) for that too.

### VirtualBox

VirtualBox is a popular VM runner. [You can run Omarchy inside that too](https://github.com/omacom/omarchy/discussions/176). But performance probably won't be great.

### VMware Workstation on Windows 11

Another popular VM runner for Windows. [Omarchy has been setup inside of that as well](https://github.com/omacom/omarchy/discussions/572).

### Steam Deck

The Steam Deck runs on Arch, which means you can run Omarchy on your Steam Deck. Altynbek Orumbayev has [a full setup script and explanation on how to do it](https://github.com/aorumbayev/deckarchy). How cool is that!

### NixOS

Omarchy is really Arch + Hyprland, but Henry Sipp has [ported the essence of the setup to NixOS](https://github.com/henrysipp/omarchy-nix). So if you've been nix-pilled, here's a good starting point. It may or may not stay up-to-date with the latest Omarchy changes, but it's pretty cool none the less!

### Something else!

If you're trying to get Omarchy running on a configuration that isn't the default, you should join the #omarchy-on-other channel on [our community Discord](https://discord.gg/tXFUdasqhY).
