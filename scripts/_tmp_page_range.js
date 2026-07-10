const fs=require('fs');
const d=JSON.parse(fs.readFileSync('C:/Users/lduan/sqlcsi-archive/reports/2607060030001536_error211_dump_flood/dbcc_dumps_full.json','utf8'));
let minPage=Infinity,maxPage=-Infinity;
const pagesSet=new Set(), fileIdSet=new Set();
const perDump=[];
const extRx=/Extent \((\d+):(\d+)\)/;
const pgRx=/Page \((\d+):(\d+)\)/;
for(const x of d){
  let mn=Infinity, mx=-Infinity;
  for(const e of x.entries||[]){
    let fid=null, pg=null;
    let m=extRx.exec(e.message); if(m){fid=m[1]; pg=m[2];}
    if(!m){ m=pgRx.exec(e.message); if(m){fid=m[1]; pg=m[2];} }
    if(fid && pg){
      fileIdSet.add(fid);
      const p=parseInt(pg,10);
      pagesSet.add(p);
      if(p<minPage) minPage=p;
      if(p>maxPage) maxPage=p;
      if(p<mn) mn=p;
      if(p>mx) mx=p;
    }
  }
  perDump.push({dump:x.dumpName, ts:x.dumpTs, cnt:x.entryCount,
                firstPage: mn===Infinity?null:mn,
                lastPage:  mx===-Infinity?null:mx});
}
console.log('overall page range:', minPage, '->', maxPage);
console.log('distinct file_ids:', [...fileIdSet].join(','));
console.log('distinct pages count:', pagesSet.size);
console.log('per-dump summary:');
for(const p of perDump) console.log(' ', p.dump, p.ts, 'entries='+p.cnt, 'pages', p.firstPage, '->', p.lastPage);
