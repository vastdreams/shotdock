// electron-builder hook: re-sign the built app with the local identity (or ad-hoc) when no Developer ID was used,
// so the .dmg / .zip carry a consistent signature. With a Developer ID (CSC_LINK / keychain), this does nothing.
const { execFileSync } = require("node:child_process");
const path = require("node:path");
exports.default = async function (ctx) {
  if (ctx.electronPlatformName !== "darwin" || process.env.CSC_LINK || process.env.CSC_NAME) return;
  const app = path.join(ctx.appOutDir, `${ctx.packager.appInfo.productFilename}.app`);
  execFileSync(path.join(__dirname, "sign-local.sh"), [app], { stdio: "inherit" });
};
