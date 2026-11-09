// Keep a single monitor document alive so switching to the library does not
// release/reacquire the UVC stream. Only same-origin app links are handled.
(() => {
  const monitor=!!document.getElementById('liveVideo');
  window.name=monitor?'bird-monitor':'bird-library';
  document.querySelectorAll('a[href]').forEach(link=>{
    const url=new URL(link.getAttribute('href'),location.href);
    if(url.origin!==location.origin)return;
    const path=link.getAttribute('href').split('?')[0];
    if(monitor&&path.startsWith('/history')){
      link.target='bird-library';link.removeAttribute('rel');
    }
    if(path==='/'){
      link.target='bird-monitor';link.removeAttribute('rel');
      link.addEventListener('click',event=>{
        if(event.ctrlKey||event.metaKey||event.shiftKey||event.altKey)return;
        event.preventDefault();
        if(monitor)return;
        const existing=window.open('','bird-monitor');
        if(!existing){location.href='/';return;}
        try{
          // Opening an existing named window with an empty URL does not reload it.
          if(existing.location.origin!==location.origin||existing.location.pathname!=='/')existing.location.href='/';
        }catch(_){existing.location.href=location.origin+'/';}
        existing.focus();
      });
    }
  });
})();
