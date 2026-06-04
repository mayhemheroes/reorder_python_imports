FROM python:3.11-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends clang g++ python3-dev && \
    rm -rf /var/lib/apt/lists/*

RUN CLANG_BIN=$(which clang) pip install atheris

ADD . /src
WORKDIR /src
RUN pip install .

CMD ["/src/mayhem/fuzz_imp.py"]
