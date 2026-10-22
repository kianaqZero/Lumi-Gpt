'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const catalog=JSON.parse(fs.readFileSync(path.join(__dirname,'../i18n/catalog.json'),'utf8'));
const settings=path.join(__dirname,'../local_state/language.json');
function read(){try{const v=JSON.parse(fs.readFileSync(settings,'utf8'));if(Object.hasOwn(catalog.languages,v.locale))return v.locale;}catch{}return 'zh';}
function save(locale){if(!Object.hasOwn(catalog.languages,locale))throw Error('Unsupported locale');fs.mkdirSync(path.dirname(settings),{recursive:true});const temp=settings+'.'+crypto.randomUUID()+'.tmp';fs.writeFileSync(temp,JSON.stringify({schema:1,locale}));fs.renameSync(temp,settings);return locale;}
function text(value,locale=read()){
 if(locale==='zh'||typeof value!=='string')return value;const s=value.trim(),row=catalog.entries[s];if(row)return value.replace(s,row[locale]);
 for(const p of catalog.patterns){const re=new RegExp(p.pattern);if(re.test(s))return value.replace(s,s.replace(re,p[locale]));}
 const keys=Object.keys(catalog.entries).sort((a,b)=>b.length-a.length),re=new RegExp(keys.map(s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')).join('|'),'g');
 return value.replace(re,k=>catalog.entries[k][locale]);
}
module.exports={catalog,read,save,text};
