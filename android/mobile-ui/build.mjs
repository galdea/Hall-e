import { build } from 'esbuild';
import { compile } from 'imba/compiler';
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
const out = resolve('../app/src/main/assets/orbita');
await mkdir(out, {recursive:true});
const result = await build({entryPoints:['src/app.imba'],bundle:true,minify:true,format:'iife',platform:'browser',target:'chrome100',conditions:['browser'],loader:{'.svg':'text'},outfile:out+'/app.js',metafile:true,plugins:[{
  name:'imba', setup(b) { b.onLoad({filter:/\.imba$/},async args=>{
    const c=compile(await readFile(args.path,'utf8'),{sourcePath:args.path,target:'web'});
    const errors=c.diagnostics.filter(d=>d.severity===1).map(d=>({text:d.message}));
    if(errors.length)return {errors};
    return {contents:c.js,loader:'js',resolveDir:dirname(args.path)};
  }); }
}]});
await copyFile('src/app.css',out+'/app.css');
await copyFile('src/index.html',out+'/index.html');
for (const name of ['hall-e.webp','hal.webp','wall-e.webp']) await copyFile('src/'+name,out+'/'+name);
await copyFile('THIRD_PARTY_NOTICES.txt',out+'/THIRD_PARTY_NOTICES.txt');
const bytes=Object.values(result.metafile.outputs).reduce((sum,o)=>sum+o.bytes,0);
await writeFile(out+'/build-info.json',JSON.stringify({compiler:'imba@2.0.0-alpha.253',javascriptBytes:bytes,networkDependencies:0},null,2)+'\n');
console.log(`Imba mobile UI: ${bytes} bytes JS; packaged locally, no network assets.`);
