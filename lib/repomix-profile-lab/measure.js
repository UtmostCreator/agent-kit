#!/usr/bin/env node
// measure.js — the real-data measurer behind `restsift repomix-profile-lab`.
//
// Packs a target under several repomix "profiles" (option sets) and reports the
// EXACT token counts repomix itself computes (packResult.totalTokens, o200k_base) —
// never a bytes/4 or character heuristic. Emits one JSON object on stdout:
//
//   { schema, status, tool, target, cwd, budget, style, encoding,
//     repomix_version, faithful_tokens, profiles:[...], recommended,
//     recommended_fits, generation_command }
//
// The bash entry (libexec/repomix-profile-lab) renders the human table from this
// JSON and passes it through verbatim for --json. This helper is not a public
// entrypoint; it is invoked as: node measure.js <target> <tmpDir> <budget> <style>
//
// HARD-FAIL contract: if node cannot import the repomix library by ANY resolution
// strategy, or the installed repomix is below the version floor, print an
// actionable message to stderr and exit non-zero. No approximation, ever.

"use strict";

const path = require("path");
const fs = require("fs");

// Locate an executable on PATH without spawning a shell (portable across hosts
// that lack /bin/bash, e.g. NixOS). Returns the first executable match or null.
function findOnPath(name) {
  const dirs = (process.env.PATH || "").split(path.delimiter);
  for (const d of dirs) {
    if (!d) continue;
    const p = path.join(d, name);
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return p;
    } catch (e) {
      /* not here */
    }
  }
  return null;
}

const VERSION_FLOOR = "1.15.0";
const ENCODING = "o200k_base";

// Fidelity ranking, highest -> lowest. map-only is diagnostic and never selected.
const FIDELITY_ORDER = [
  "faithful",
  "line-numbered",
  "lean",
  "lean-no-comments",
  "compressed",
];

// Profile -> repomix runCli option overrides (real, doc-verified option keys).
const PROFILE_OPTS = {
  faithful: {},
  lean: { removeEmptyLines: true },
  "lean-no-comments": { removeEmptyLines: true, removeComments: true },
  compressed: { compress: true, removeEmptyLines: true },
  "line-numbered": { removeEmptyLines: true, outputShowLineNumbers: true },
  "map-only": { files: false },
};

// Profile -> the real repomix CLI flags a user would run to reproduce the pack.
const PROFILE_CLI_FLAGS = {
  faithful: [],
  lean: ["--remove-empty-lines"],
  "lean-no-comments": ["--remove-empty-lines", "--remove-comments"],
  compressed: ["--compress", "--remove-empty-lines"],
  "line-numbered": ["--remove-empty-lines", "--output-show-line-numbers"],
  "map-only": ["--no-files"],
};

const STYLE_EXT = { xml: "xml", markdown: "md", plain: "txt" };

function fail(msg, code) {
  process.stderr.write("repomix-profile-lab: " + msg + "\n");
  process.exit(code || 3);
}

// Robust repomix resolution. Returns { mod, pkgDir, version } or hard-fails.
function resolveRepomix() {
  // Test/hard-fail hook: force the resolver to find nothing.
  if (process.env.REPOMIX_PROFILE_LAB_FORCE_NO_REPOMIX === "1") {
    fail(
      "repomix library not found (forced via REPOMIX_PROFILE_LAB_FORCE_NO_REPOMIX). " +
        "Unset it to resolve repomix normally.",
      3
    );
  }

  const tried = [];

  // Strategy 1: plain module resolution (works when repomix is a real dep).
  try {
    const pkgJson = require.resolve("repomix/package.json");
    const pkgDir = path.dirname(pkgJson);
    return loadFrom(pkgDir);
  } catch (e) {
    tried.push("require('repomix')");
  }

  const candidates = [];

  // Strategy 2: explicit override (also used by tests to pin the nix store copy).
  if (process.env.REPOMIX_LIB_DIR) {
    candidates.push(path.join(process.env.REPOMIX_LIB_DIR, "repomix"));
  }

  // Strategy 3: derive from the on-PATH repomix binary (nix layout:
  // <storeRoot>/bin/repomix -> <storeRoot>/lib/node_modules/repomix). Resolved
  // shell-free (no /bin/bash dependency; NixOS hosts may not ship /bin/bash) by
  // scanning PATH and following symlinks with realpath (== readlink -f).
  try {
    const binPath = findOnPath("repomix");
    if (binPath) {
      const binReal = fs.realpathSync(binPath);
      const storeRoot = path.dirname(path.dirname(binReal));
      candidates.push(path.join(storeRoot, "lib", "node_modules", "repomix"));
    } else {
      tried.push("repomix (not on PATH)");
    }
  } catch (e) {
    tried.push("on-PATH repomix realpath");
  }

  // Strategy 4: npx cache fallback (~/.npm/_npx/*/node_modules/repomix).
  try {
    const home = process.env.HOME || require("os").homedir();
    const npxRoot = path.join(home, ".npm", "_npx");
    if (fs.existsSync(npxRoot)) {
      for (const entry of fs.readdirSync(npxRoot)) {
        candidates.push(
          path.join(npxRoot, entry, "node_modules", "repomix")
        );
      }
    }
  } catch (e) {
    /* ignore */
  }

  for (const pkgDir of candidates) {
    tried.push(pkgDir);
    try {
      if (fs.existsSync(path.join(pkgDir, "package.json"))) {
        return loadFrom(pkgDir);
      }
    } catch (e) {
      /* try next */
    }
  }

  fail(
    "could not import the repomix library by any strategy.\n" +
      "  Tried: " +
      tried.join(", ") +
      "\n" +
      "  Fix: install repomix (npm i -g repomix) so it is on PATH, or set\n" +
      "  REPOMIX_LIB_DIR to the directory that contains a 'repomix' package.",
    3
  );
}

function loadFrom(pkgDir) {
  const version = require(path.join(pkgDir, "package.json")).version;
  if (cmpVersion(version, VERSION_FLOOR) < 0) {
    fail(
      "repomix " +
        version +
        " is below the required floor " +
        VERSION_FLOOR +
        ". Upgrade repomix (npm i -g repomix).",
      4
    );
  }
  let mod;
  try {
    mod = require(pkgDir);
  } catch (e) {
    fail(
      "found repomix " +
        version +
        " at " +
        pkgDir +
        " but could not require its entry module: " +
        e.message,
      3
    );
  }
  if (typeof mod.runCli !== "function") {
    fail(
      "repomix at " + pkgDir + " does not export runCli; incompatible build.",
      4
    );
  }
  return { mod, pkgDir, version };
}

// Numeric semver-ish compare of dotted versions (ignores pre-release tags).
function cmpVersion(a, b) {
  const pa = String(a).split(".").map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

function buildGenerationCommand(profile, target, style) {
  const ext = STYLE_EXT[style] || "xml";
  const flags = PROFILE_CLI_FLAGS[profile] || [];
  const parts = ["repomix", quoteArg(target), "--style", style];
  for (const f of flags) parts.push(f);
  // map-only produces no file body; still show a real, runnable command.
  if (profile !== "map-only") {
    parts.push("--output", "repomix-" + profile + "." + ext);
  }
  return parts.join(" ");
}

function quoteArg(s) {
  return /[^A-Za-z0-9_.\/-]/.test(s) ? "'" + s.replace(/'/g, "'\\''") + "'" : s;
}

async function main() {
  const target = process.argv[2];
  const tmpDir = process.argv[3];
  const budget = parseInt(process.argv[4], 10);
  const style = process.argv[5] || "xml";
  const cwd = process.cwd();

  if (!target || !tmpDir || !Number.isFinite(budget)) {
    fail("internal: measure.js requires <target> <tmpDir> <budget> [style]", 2);
  }
  if (!STYLE_EXT[style]) {
    fail("unsupported style '" + style + "' (use xml, markdown, or plain)", 2);
  }

  const { mod, version } = resolveRepomix();
  const { runCli } = mod;
  const ext = STYLE_EXT[style];

  const results = [];
  let faithfulTokens = null;

  for (const profile of Object.keys(PROFILE_OPTS)) {
    const opts = Object.assign(
      {
        output: path.join(tmpDir, "profile-" + profile + "." + ext),
        style: style,
        quiet: true,
        securityCheck: false,
      },
      PROFILE_OPTS[profile]
    );

    let pr;
    try {
      const r = await runCli([target], cwd, opts);
      pr = r && r.packResult;
    } catch (e) {
      fail(
        "repomix failed while packing profile '" + profile + "': " + e.message,
        5
      );
    }
    if (!pr || typeof pr.totalTokens !== "number") {
      fail(
        "repomix returned no packResult.totalTokens for profile '" +
          profile +
          "' (incompatible repomix build).",
        5
      );
    }

    if (profile === "faithful") faithfulTokens = pr.totalTokens;

    results.push({
      profile: profile,
      totalTokens: pr.totalTokens,
      totalFiles: pr.totalFiles,
      totalCharacters: pr.totalCharacters,
      diagnostic: profile === "map-only",
      selectable: profile !== "map-only",
    });
  }

  // % reduction vs faithful (real counts; positive = smaller than faithful).
  for (const r of results) {
    r.fits = r.totalTokens <= budget;
    r.reductionPct =
      faithfulTokens && faithfulTokens > 0
        ? Number(
            (((faithfulTokens - r.totalTokens) / faithfulTokens) * 100).toFixed(2)
          )
        : 0;
  }

  // Selection: highest-fidelity selectable profile whose tokens fit the budget.
  // Fidelity order is strict, so "tie-break by fewer tokens" only ever matters
  // among equal-fidelity entries (none here) — the first fitting entry wins.
  const byName = Object.fromEntries(results.map((r) => [r.profile, r]));
  let recommended = null;
  let recommendedFits = false;
  for (const name of FIDELITY_ORDER) {
    const r = byName[name];
    if (r && r.fits) {
      recommended = name;
      recommendedFits = true;
      break;
    }
  }
  if (!recommended) {
    // Nothing fits: recommend the smallest selectable profile as best-effort,
    // and flag that it does not fit so the caller does not over-trust it.
    let best = null;
    for (const name of FIDELITY_ORDER) {
      const r = byName[name];
      if (!r) continue;
      if (!best || r.totalTokens < byName[best].totalTokens) best = name;
    }
    recommended = best;
    recommendedFits = false;
  }

  const out = {
    schema: "ai.repomix-profile-lab/v1",
    status: "ok",
    tool: "repomix-profile-lab",
    target: target,
    cwd: cwd,
    budget: budget,
    style: style,
    encoding: ENCODING,
    repomix_version: version,
    faithful_tokens: faithfulTokens,
    profiles: results,
    recommended: recommended,
    recommended_fits: recommendedFits,
    generation_command: buildGenerationCommand(recommended, target, style),
  };

  process.stdout.write(JSON.stringify(out) + "\n");
}

main().catch((e) => {
  fail("unexpected error: " + (e && e.stack ? e.stack : e), 1);
});
