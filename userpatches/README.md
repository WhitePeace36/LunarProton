# Your own patches

Put patches in a folder named after the component they patch, and they are
applied (in name order, `patch -p1`, no fuzz) after GE's patches and the
lunar patch set:

    userpatches/wine/*.patch           Wine
    userpatches/dxvk/*.patch           DXVK
    userpatches/vkd3d-proton/*.patch   VKD3D-Proton
    userpatches/<submodule>/*.patch    any other submodule of GE-Proton
    userpatches/top/*.patch            the GE-Proton tree itself

Set `_user_patches="false"` to build without them. A patch that does not apply
stops the build before anything is compiled.
