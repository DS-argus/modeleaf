#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/modeleaf-config.XXXXXX")
GENERATOR="$WORK/main.swift"
BINARY="$WORK/generate-config-artifacts"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

cat >"$GENERATOR" <<'SWIFT'
import Foundation

@main
struct GenerateConfigArtifacts {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw GenerationError.missingRepositoryRoot
        }
        let root = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        try Data(BuiltInDefaults.defaultConfigTOML.utf8).write(
            to: root.appendingPathComponent("PDFReaderApp/Resources/DefaultConfig.toml"),
            options: .atomic
        )
        try Data(ConfigDocumentation.markdown.utf8).write(
            to: root.appendingPathComponent("CONFIG.md"),
            options: .atomic
        )
    }
}

enum GenerationError: Error {
    case missingRepositoryRoot
}
SWIFT

find "$ROOT/PDFReaderCore" -name '*.swift' -print0 \
  | xargs -0 swiftc -parse-as-library "$GENERATOR" -o "$BINARY"
"$BINARY" "$ROOT"

printf '%s\n' \
  "$ROOT/PDFReaderApp/Resources/DefaultConfig.toml" \
  "$ROOT/CONFIG.md"
