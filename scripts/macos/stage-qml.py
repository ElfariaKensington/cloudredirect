#!/usr/bin/env python3
"""Copy runtime QML modules used by the app, excluding unrelated Qt tools."""
import pathlib, shutil, sys
source, destination=map(pathlib.Path,sys.argv[1:])
modules=['QtQml','QtQml/Models','QtQml/WorkerScript','QtQuick','QtQuick/Window','QtQuick/Layouts','QtQuick/Templates','QtQuick/Controls','QtQuick/Controls/impl','QtQuick/Controls/Basic','QtQuick/Controls/Fusion','QtQuick/Controls/Basic/impl','QtQuick/Controls/Fusion/impl','QtQuick/Dialogs','QtQuick/Dialogs/quickimpl','QtQuick/NativeStyle','QtQuick/Effects','QtCore','Qt/labs/folderlistmodel','Qt/labs/settings']
for module in modules:
    directory=source/module
    if not directory.is_dir():continue
    target=destination/module;target.mkdir(parents=True,exist_ok=True)
    # Some style modules use ordinary nested directories for their components.
    for file in directory.iterdir():
        if file.is_file():shutil.copy2(file,target/file.name,follow_symlinks=True)
