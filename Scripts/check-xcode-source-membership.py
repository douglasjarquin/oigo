#!/usr/bin/env python3
"""Fail unless each production Swift file is compiled into the matching Xcode target."""

import json
import os
import subprocess
import sys

REQUIRED_PRODUCTION_ROOTS = {
    "Sources/Oigo": "Oigo",
    "Sources/OigoCore": "OigoCore",
    "Sources/OigoCapture": "OigoCapture",
    "Sources/OigoTranscription": "OigoTranscription",
    "Sources/OigoInsertion": "OigoInsertion",
    "Sources/OigoHotKey": "OigoHotKey",
}

OPTIONAL_DECLARED_ROOTS = {
    "Sources/MacUtilityUI": "MacUtilityUI",
    "Sources/OigoUIGallery": "OigoUIGallery",
}

DECLARED_ROOTS = REQUIRED_PRODUCTION_ROOTS | OPTIONAL_DECLARED_ROOTS


def load_objects(pbxproj):
    converted = subprocess.check_output(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", pbxproj]
    )
    project = json.loads(converted)
    objects = project.get("objects")
    if not isinstance(objects, dict):
        raise SystemExit("Oigo.xcodeproj project.pbxproj has no objects dictionary")
    return objects


def group_parents(objects):
    parents = {}
    for object_id, obj in objects.items():
        if obj.get("isa") != "PBXGroup":
            continue
        for child in obj.get("children", []):
            parents[child] = object_id
    return parents


def group_filesystem_path(objects, group_id, parents, cache):
    if group_id in cache:
        return cache[group_id]
    obj = objects.get(group_id, {})
    own_path = obj.get("path")
    parent_id = parents.get(group_id)
    if parent_id is None:
        result = own_path or ""
    else:
        prefix = group_filesystem_path(objects, parent_id, parents, cache)
        if own_path:
            result = os.path.join(prefix, own_path) if prefix else own_path
        else:
            result = prefix
    cache[group_id] = result
    return result


def file_repo_path(objects, file_ref_id, parents, cache):
    file_ref = objects.get(file_ref_id, {})
    name = file_ref.get("path")
    if not name:
        return None
    parent_id = parents.get(file_ref_id)
    if parent_id is None:
        return os.path.normpath(name)
    prefix = group_filesystem_path(objects, parent_id, parents, cache)
    joined = os.path.join(prefix, name) if prefix else name
    return os.path.normpath(joined)


def compiled_paths_by_target(objects, repo_root):
    parents = group_parents(objects)
    cache = {}
    phase_to_target = {}
    for obj in objects.values():
        if obj.get("isa") != "PBXNativeTarget":
            continue
        target_name = obj.get("name")
        for phase_id in obj.get("buildPhases", []):
            phase = objects.get(phase_id, {})
            if phase.get("isa") == "PBXSourcesBuildPhase":
                phase_to_target[phase_id] = target_name

    compiled = {}
    for phase_id, target_name in phase_to_target.items():
        phase = objects[phase_id]
        compiled.setdefault(target_name, set())
        for build_file_id in phase.get("files", []):
            build_file = objects.get(build_file_id, {})
            file_ref_id = build_file.get("fileRef")
            path = file_repo_path(objects, file_ref_id, parents, cache)
            if not path or not path.endswith(".swift"):
                raise SystemExit(
                    "Xcode target %s sources phase includes a non-Swift file: %s"
                    % (target_name, path)
                )
            compiled[target_name].add(path)

    for obj in objects.values():
        if obj.get("isa") != "PBXNativeTarget":
            continue
        target_name = obj.get("name")
        compiled.setdefault(target_name, set())
        for group_id in obj.get("fileSystemSynchronizedGroups", []):
            group = objects.get(group_id, {})
            if group.get("isa") != "PBXFileSystemSynchronizedRootGroup":
                raise SystemExit(
                    "Xcode target %s has an invalid synchronized source group"
                    % target_name
                )
            relative_root = os.path.normpath(group.get("path", ""))
            if not relative_root or relative_root.startswith(".."):
                raise SystemExit(
                    "Xcode target %s has an unsafe synchronized source root"
                    % target_name
                )
            directory = os.path.join(repo_root, relative_root)
            for walk_root, _, filenames in os.walk(directory):
                for name in filenames:
                    if name.endswith(".swift"):
                        full = os.path.join(walk_root, name)
                        compiled[target_name].add(
                            os.path.normpath(os.path.relpath(full, repo_root))
                        )
    if not compiled:
        raise SystemExit("Oigo.xcodeproj has no Swift sources phases")
    return compiled


def disk_paths_by_target(repo_root):
    expected = {}
    for relative_root, target in DECLARED_ROOTS.items():
        directory = os.path.join(repo_root, relative_root)
        if not os.path.isdir(directory):
            if relative_root in REQUIRED_PRODUCTION_ROOTS:
                raise SystemExit("%s is missing" % relative_root)
            continue
        expected.setdefault(target, set())
        found = False
        for walk_root, _, filenames in os.walk(directory):
            for name in filenames:
                if not name.endswith(".swift"):
                    continue
                found = True
                full = os.path.join(walk_root, name)
                rel = os.path.relpath(full, repo_root)
                expected[target].add(os.path.normpath(rel))
        if not found and relative_root in REQUIRED_PRODUCTION_ROOTS:
            raise SystemExit("%s has no Swift sources" % relative_root)
    return expected


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: %s <repo-root>" % sys.argv[0])
    repo_root = os.path.abspath(sys.argv[1])
    pbxproj = os.path.join(repo_root, "Oigo.xcodeproj/project.pbxproj")
    objects = load_objects(pbxproj)
    compiled = compiled_paths_by_target(objects, repo_root)
    expected = disk_paths_by_target(repo_root)
    problems = []
    for target in sorted(set(compiled) | set(expected)):
        if target not in DECLARED_ROOTS.values() and compiled.get(target):
            problems.append(
                "unexpected Xcode native target compiles Swift: %s (%s)"
                % (target, ", ".join(sorted(compiled[target])))
            )
            continue
        want = expected.get(target, set())
        have = compiled.get(target, set())
        missing = sorted(want - have)
        extra = sorted(have - want)
        if missing:
            problems.append(
                "%s missing from Xcode target: %s" % (target, ", ".join(missing))
            )
        if extra:
            problems.append(
                "%s compiles paths not in its production root: %s"
                % (target, ", ".join(extra))
            )
    if problems:
        raise SystemExit("; ".join(problems))
    print("GREEN: every production source is compiled into the correct Xcode target")


if __name__ == "__main__":
    main()
