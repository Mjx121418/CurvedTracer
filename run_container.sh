container run --rm -it \
    --name curved-dev \
    --cpus 4 \
    --memory 4G \
    -p 127.0.0.1:3080:3081 \
    -v "$PWD":/workspace \
    -v dsh-data:/root/.dsh \
    -v codex-data:/root/.codex \
    -w /workspace \
    curved-dev