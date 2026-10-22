'use strict';
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../src');let count=0;
function visit(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,entry.name);if(entry.isDirectory())visit(file);else if(/\.(?:cjs|js)$/.test(entry.name)){const result=spawnSync(process.execPath,['--check',file],{encoding:'utf8',windowsHide:true});assert.equal(result.status,0,path.relative(root,file)+'\n'+result.stderr);count++;}}}
visit(root);console.log('PASS:',count,'JavaScript source syntax checks');
