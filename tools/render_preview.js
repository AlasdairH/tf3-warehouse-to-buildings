// Renders assets/preview.svg to the mod's preview image (_metadata/0.png, 1920x1080).
// Needs @resvg/resvg-js: npm install --prefix tools/.cache @resvg/resvg-js
// Usage: node tools/render_preview.js
const fs = require("fs");
const path = require("path");
const root = path.join(__dirname, "..");
let Resvg;
try {
	({ Resvg } = require(path.join(__dirname, ".cache", "node_modules", "@resvg", "resvg-js")));
} catch (e) {
	({ Resvg } = require("@resvg/resvg-js"));
}
const svg = fs.readFileSync(path.join(root, "assets", "preview.svg"));
const png = new Resvg(svg, {
	fitTo: { mode: "width", value: 1920 },
	font: { loadSystemFonts: true, defaultFontFamily: "DejaVu Sans" },
}).render().asPng();
const out = path.join(root, "mod", "warehouse_distribution_1", "_metadata", "0.png");
fs.writeFileSync(out, png);
console.log(`${out}: ${png.length} bytes`);
