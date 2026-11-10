# GNOME Build Metadata

[gnome-build-meta](https://gitlab.gnome.org/GNOME/gnome-build-meta) is one repo. It builds the GNOME platform and publishes it.

- The platform is GNOME OS, the Flatpak runtime, and the SDK
- The repo holds the recipes. Library source is fetched from each upstream project
- One command compiles each library, then packs the results
- CI publishes the images and runtimes

Same shape as [pixiewood-pkgs](https://github.com/roojs/pixiewood-pkgs): one repo, one build, each library compiled on its own. A GNOME recipe lists the libraries it needs. pixiewood-pkgs uses `build-order.txt` for that order.

Fixed set, updated by hand:

- Each library has a commit written down in the repo
- A build uses those commits
- A person updates a commit when the set should move
- The development line is updated often, toward the branch tip
- A release line stays until the next release or fix

Steps forward:

- Propose that this build also publish a Pixie package for each library it already builds
- Their existing library list is the queue
- One commit of gnome-build-meta is one published set
- The next set is the next time they update those commits and rebuild
- pixiewood-pkgs would download that set instead of building the same libraries
- Their OS image, Flatpak runtime, and SDK stay as they are. The Pixie packages are an extra output
