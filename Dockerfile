FROM eclipse-temurin:21-jdk

ENV DEBIAN_FRONTEND=noninteractive
ENV CPG_PYTHON_VIRTUALENV=/root/.virtualenvs/cpg
ENV JEP_LIBRARY_PATH=/root/.virtualenvs/cpg/lib/python3.14/site-packages/jep
ENV PYTHONPATH=/root/.virtualenvs/cpg/lib/python3.14/site-packages

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        git \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /root/.virtualenvs/cpg \
    && /root/.virtualenvs/cpg/bin/pip install --no-cache-dir --upgrade pip \
    && /root/.virtualenvs/cpg/bin/pip install --no-cache-dir jep

WORKDIR /work
