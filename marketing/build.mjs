// Renders every marketing shot to static HTML in out/, plus a render list
// consumed by compose-screenshots.sh. React JSX is compiled with esbuild.
import { build } from "esbuild";
import { mkdir, writeFile, rm } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, "out");
const tmpDir = path.join(here, ".tmp");

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });
await mkdir(tmpDir, { recursive: true });

await build({
  entryPoints: [path.join(here, "shots.jsx")],
  bundle: true,
  format: "esm",
  jsx: "automatic",
  outfile: path.join(tmpDir, "shots.mjs"),
  packages: "external"
});

const { manifest } = await import(pathToFileURL(path.join(tmpDir, "shots.mjs")).href);
const { renderToStaticMarkup } = await import("react-dom/server");

const jobs = manifest("captures/icon.png");
const lines = [];
for (const job of jobs) {
  const markup = renderToStaticMarkup(job.element);
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>*{margin:0;padding:0;box-sizing:border-box}img{-webkit-user-drag:none}</style></head><body>${markup}</body></html>`;
  const htmlPath = path.join(outDir, `${job.name}.html`);
  await writeFile(htmlPath, html);
  lines.push([`out/${job.name}.html`, `out/${job.name}.png`, job.width, job.height].join("\t"));
}
await writeFile(path.join(outDir, "render-list.tsv"), lines.join("\n") + "\n");
console.log(`built ${jobs.length} shots -> out/`);
