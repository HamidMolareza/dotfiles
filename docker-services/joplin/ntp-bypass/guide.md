docker cp ntp-bypass.patch joplin-app-1:/tmp/
docker exec -it joplin-app-1 bash
cp /tmp/ntp-bypass.patch /home/joplin/packages/lib/vendor/ntp-client.js