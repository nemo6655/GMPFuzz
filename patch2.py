import os
with open("run_mongoose_ablation_supplement.sh", "r") as f:
    c = f.read()
c = c.replace("gcovr -r /home/ubuntu/experiments/mongoose-gcov -s -d > /dev/null 2>&1 || true", "gcovr -r /home/ubuntu/experiments/mongoose-src --object-directory /home/ubuntu/experiments/mongoose-gcov -s -d > /dev/null 2>&1 || true")
c = c.replace("gcovr -r /home/ubuntu/experiments/mongoose-gcov -s || true", "gcovr -r /home/ubuntu/experiments/mongoose-src --object-directory /home/ubuntu/experiments/mongoose-gcov -s || true")
with open("run_mongoose_ablation_supplement.sh", "w") as f:
    f.write(c)
