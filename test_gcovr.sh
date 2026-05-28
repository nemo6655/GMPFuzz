#!/bin/bash
docker run --rm gmpfuzz/mongoose /bin/bash -c "
cd /home/ubuntu/experiments/mongoose-gcov
./mongoose_mqtt_broker mqtt://0.0.0.0:1883 &
PID=\$!
sleep 1
kill -TERM \$PID
wait \$PID 2>/dev/null
ls -l /home/ubuntu/experiments/mongoose-gcov/*.gcda
"
