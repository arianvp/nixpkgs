#!/usr/bin/env python

"""Amend systemd-repart definiton files.

In order to avoid Import-From-Derivation (IFD) when building images with
systemd-repart, the definition files created by Nix need to be amended with the
store paths from the closure.

This is achieved by adding CopyFiles= instructions to the definition files.

The arbitrary files configured via `contents` are also added to the definition
files using the same mechanism.
"""

import json
import sys
import shutil
from pathlib import Path


def add_contents_to_definition(
    definition: Path, contents: dict[str, dict[str, str]] | None
) -> None:
    """Add CopyFiles= instructions to a definition for all files in contents."""
    if not contents:
        return

    copy_files_lines: list[str] = []
    for target, options in contents.items():
        source = options["source"]

        copy_files_lines.append(f"CopyFiles={source}:{target}\n")

    with open(definition, "a") as f:
        f.writelines(copy_files_lines)


def add_closure_to_definition(
    definition: Path, closure: Path | None, target_prefix: str = "/nix/store"
) -> None:
    """Add CopyFiles= instructions to a definition for all paths in the closure.

    target_prefix tells what directory to move the nix store paths into.
    By default it copies to "/nix/store"

    Setting target_prefix to "/" creates a nix-store partition
    that you can mount under "/nix/store"

    Other option is to set target_prefix to "/store" on a usr partition
    and then bind-mount "/usr/store" to "/nix/store".  This allows
    you to re-use all of systemd's verity logic for usr partitions
    """
    if not closure:
        return

    copy_files_lines: list[str] = []
    with open(closure, "r") as f:
        for line in f:
            if not isinstance(line, str):
                continue

            source = Path(line.strip())
            source_prefix = "/nix/store"
            target = Path(target_prefix).joinpath(source.relative_to(source_prefix))
            copy_files_lines.append(f"CopyFiles={source}:{target}\n")

    with open(definition, "a") as f:
        f.writelines(copy_files_lines)


def main() -> None:
    """Amend the provided repart definitions by adding CopyFiles= instructions.

    For each file specified in the `contents` field of a partition in the
    partiton config file, a `CopyFiles=` instruction is added to the
    corresponding definition file.

    The same is done for every store path of the `closure` field.

    Print the path to a directory that contains the amended repart
    definitions to stdout.
    """
    partition_config_file = sys.argv[1]
    if not partition_config_file:
        print("No partition config file was supplied.")
        sys.exit(1)

    repart_definitions = sys.argv[2]
    if not repart_definitions:
        print("No repart definitions were supplied.")
        sys.exit(1)

    with open(partition_config_file, "rb") as f:
        partition_config = json.load(f)

    if not partition_config:
        print("Partition config is empty.")
        sys.exit(1)

    target_dir = Path("amended-repart.d")
    target_dir.mkdir()
    shutil.copytree(repart_definitions, target_dir, dirs_exist_ok=True)

    for name, config in partition_config.items():
        definition = target_dir.joinpath(f"{name}.conf")
        definition.chmod(0o644)

        contents = config.get("contents")
        add_contents_to_definition(definition, contents)

        closure = config.get("closure")
        target_prefix = config.get("targetPrefix")
        add_closure_to_definition(definition, closure, target_prefix)

    print(target_dir.absolute())


if __name__ == "__main__":
    main()
