import json, times
let t = epochTime()
for l in lines("j"):
  discard parseJson(l)
echo epochTime() - t
