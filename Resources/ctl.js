// Sidecar control via the private SidecarCore framework.
// usage: osascript -l JavaScript ctl.js <connect|disconnect|list> [deviceName]
// Note: SidecarDisplayManager is a private API and may break on major macOS updates.
function run(argv){
  ObjC.import('Foundation');
  $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/SidecarCore.framework').load;
  const mgr = $.NSClassFromString('SidecarDisplayManager').sharedManager;
  const action = argv[0] || 'list';
  const want = argv[1] || null;
  function find(arr){
    if(!arr || !arr.count) return null;
    for(let i=0;i<arr.count;i++){ const d=arr.objectAtIndex(i);
      if(!want || ObjC.unwrap(d.name)===want) return d; }
    return null;
  }
  if(action==='list'){
    let o=[]; const a=mgr.devices; for(let i=0;i<a.count;i++) o.push(ObjC.unwrap(a.objectAtIndex(i).name));
    let c=[]; const b=mgr.connectedDevices; for(let i=0;i<b.count;i++) c.push(ObjC.unwrap(b.objectAtIndex(i).name));
    return "devices="+JSON.stringify(o)+" connected="+JSON.stringify(c);
  }
  const dev = find(mgr.devices);
  if(!dev) return "ERR: device not found";
  if(action==='connect'){ mgr.connectToDeviceCompletion(dev, $()); return "connect sent -> "+ObjC.unwrap(dev.name); }
  if(action==='disconnect'){ mgr.disconnectFromDeviceCompletion(dev, $()); return "disconnect sent -> "+ObjC.unwrap(dev.name); }
  return "ERR: unknown action";
}
