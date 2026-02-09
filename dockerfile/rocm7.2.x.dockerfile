ARG BASE_IMAGE=rocm/pytorch:rocm7.2_ubuntu22.04_py3.10_pytorch_release_2.8.0
#rocm/pytorch:rocm7.2_ubuntu22.04_py3.12_pytorch_release_2.8.0
ARG AMD_GPU_ARCH="gfx942"
#RUN echo ${AMD_GPU_ARCH}
FROM ${BASE_IMAGE}

# OS:
#   - Ubuntu: 22.04
#   - Docker Client: 20.10.8
# ROCm:
#   - ROCm: 7.2
# Lib:
#   - torch: 2.8.0
#   - rccl: 2.18.3+hip6.0 develop:7e1cbb4
#   - hipblaslt: release-staging/rocm-rel-6.2
#   - rocblas: release-staging/rocm-rel-6.2
#   - openmpi: 5.0.9
#   - UCX: 1.19.0
# Intel:
#   - mlc: v3.12

LABEL maintainer="SuperBench"
#RUN echo ${AMD_GPU_ARCH}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get -q install -y --no-install-recommends  \
    autoconf \
    automake \
    bc \
    build-essential \
    curl \
    dmidecode \
    git \
    hipify-clang \
    iproute2 \
    jq \
    libaio-dev \
    libboost-program-options-dev \
    libcap2 \
    libcurl4-openssl-dev \
    libnuma-dev \
    libpci-dev \
    libssl-dev \
    libtool \
    lshw \
    net-tools \
    numactl \
    openssh-client \
    openssh-server \
    pciutils \
    python3-mpi4py \
    rsync \
    sudo \
    util-linux \
    vim \
    wget \
    && \
    rm -rf /tmp/*

ARG NUM_MAKE_JOBS=64

# Check if CMake is installed and its version
RUN cmake_version=$(cmake --version 2>/dev/null | grep -oP "(?<=cmake version )(\d+\.\d+)" || echo "0.0") && \
    required_version="3.31.11" && \
    if [ "$(printf "%s\n" "$required_version" "$cmake_version" | sort -V | head -n 1)" != "$required_version" ]; then \
    echo "existing cmake version is ${cmake_version}" && \
    cd /tmp && \
    wget -q https://github.com/Kitware/CMake/releases/download/v${required_version}/cmake-${required_version}.tar.gz && \
    tar xzf cmake-${required_version}.tar.gz && \
    cd cmake-${required_version} && \
    ./bootstrap --prefix=/usr --no-system-curl --parallel=16 && \
    make -j ${NUM_MAKE_JOBS} && \
    make install && \
    rm -rf /tmp/cmake-${required_version}* \
    else \
    echo "CMake version is greater than or equal to 3.31.11"; \
    fi

# Install Docker
ENV DOCKER_VERSION=20.10.8
RUN cd /tmp && \
    wget -q https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz -O docker.tgz && \
    tar --extract --file docker.tgz --strip-components 1 --directory /usr/local/bin/ && \
    rm docker.tgz

# Update system config
RUN mkdir -p /root/.ssh && \
    touch /root/.ssh/authorized_keys && \
    mkdir -p /var/run/sshd && \
    sed -i "s/[# ]*PermitRootLogin prohibit-password/PermitRootLogin yes/" /etc/ssh/sshd_config && \
    sed -i "s/[# ]*PermitUserEnvironment no/PermitUserEnvironment yes/" /etc/ssh/sshd_config && \
    sed -i "s/[# ]*Port.*/Port 22/" /etc/ssh/sshd_config && \
    echo "* soft nofile 1048576\n* hard nofile 1048576" >> /etc/security/limits.conf && \
    echo "root soft nofile 1048576\nroot hard nofile 1048576" >> /etc/security/limits.conf


# Get Ubuntu version and set as an environment variable
RUN export UBUNTU_VERSION=$(lsb_release -r -s)
RUN echo "Ubuntu version: $UBUNTU_VERSION"
ENV UBUNTU_VERSION=22.04
#${UBUNTU_VERSION}

# Install OFED
ENV OFED_VERSION=5.9-0.5.6.0
# Check if ofed_info is present and has a version
RUN if ! command -v ofed_info >/dev/null 2>&1; then \
    echo "OFED not found. Installing OFED..."; \
    cd /tmp && \
    wget -q http://content.mellanox.com/ofed/MLNX_OFED-${OFED_VERSION}/MLNX_OFED_LINUX-${OFED_VERSION}-ubuntu${UBUNTU_VERSION}-x86_64.tgz && \
    tar xzf MLNX_OFED_LINUX-${OFED_VERSION}-ubuntu${UBUNTU_VERSION}-x86_64.tgz && \
    PATH=/usr/bin:${PATH} MLNX_OFED_LINUX-${OFED_VERSION}-ubuntu${UBUNTU_VERSION}-x86_64/mlnxofedinstall --user-space-only --without-fw-update \
  --force --all && \
    rm -rf MLNX_OFED_LINUX-${OFED_VERSION}* ; \
    fi
WORKDIR /tmp
# Install UCX
ENV ROCM_PATH=/opt/rocm
ENV UCX_VER=1.19.0
ENV UCX_HOME=/usr/local/ucx
RUN wget https://github.com/openucx/ucx/archive/refs/tags/v$UCX_VER.tar.gz \
    && tar -xzf v$UCX_VER.tar.gz \
    && cd ucx-$UCX_VER  \
    && autoreconf -f -i \
    && mkdir build \
    && cd build \
    && ../contrib/configure-release  --prefix=$UCX_HOME --with-rocm=$ROCM_PATH --without-cuda  --enable-mt  --disable-logging --disable-debug \
       --disable-assertions --enable-params-check --enable-examples --enable-gtest --without-java  --without-knem  \
    && make V=1 \
    && make V=1 install \
    && rm -rf ucx-$UCX_VER  v$UCX_VER.tar.gz
#Install OpenMPI 
WORKDIR /tmp
ENV OMPI_VER=5.0.9
ENV MPI_HOME=/usr/local/mpi
ENV OMPI_ALLOW_RUN_AS_ROOT=1 
ENV OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
ENV OMPI_MCA_pml=ucx
ENV OMPI_MCA_osc=ucx
ENV OMPI_MCA_pml_ucx_tls=any 
ENV OMPI_MCA_pml_ucx_devices=any 
ENV OMPI_MCA_pml_ucx_verbose=100
# export C_COMPILER=gcc && export CXX_COMPILER=g++ && export FC_COMPILER=gfortran   
RUN wget https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-$OMPI_VER.tar.gz \
    && tar xzf openmpi-$OMPI_VER.tar.gz \
    && cd openmpi-$OMPI_VER \
    && mkdir build \
    && cd build \
    && ../configure --prefix=$MPI_HOME --with-ucx=$UCX_HOME --with-rocm=/opt/rocm  --enable-mca-no-build=btl-uct --enable-mpi \
      --disable-debug CC=gcc CXX=g++ \
    && make V=1 \
    && make V=1 install \
    && rm -rf /tmp/openmpi-$OMPI_VER  openmpi-$OMPI_VER.tar.gz
#Install Intel MLC
WORKDIR /tmp
RUN wget -q  https://downloadmirror.intel.com/866182/mlc_v3.12.tgz -O mlc.tgz \
    && tar xzf mlc.tgz Linux/mlc \
    && cp ./Linux/mlc /usr/local/bin/ \
    && rm -rf ./Linux mlc.tgz 

# Install AMD SMI Python Library
RUN apt install amd-smi-lib rocm-cmake -y  \
    && cd /opt/rocm/share/amd_smi \
    &&  python3 -m pip install --upgrade pip wheel \
    && python3 -m pip install . 
   
ENV PATH="/usr/local/mpi/bin:/usr/local/ucx/bin/:/opt/superbench/bin:/usr/local/bin/:/opt/rocm/bin/:/opt/rocm/lib/llvm/bin/:${PATH}" 
ENV LD_LIBRARY_PATH="/usr/local/mpi/lib:/usr/local/ucx/lib:/usr/lib/x86_64-linux-gnu/:/usr/local/lib/:/opt/rocm/lib:${LD_LIBRARY_PATH}" 
ENV SB_HOME=/opt/superbench 
ENV SB_MICRO_PATH=/opt/superbench 
ENV ANSIBLE_DEPRECATION_WARNINGS=FALSE 
ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections
RUN echo PATH="$PATH" > /etc/environment \
    && echo LD_LIBRARY_PATH="$LD_LIBRARY_PATH" >> /etc/environment \
    && echo SB_MICRO_PATH="$SB_MICRO_PATH" >> /etc/environment

WORKDIR ${SB_HOME}

ADD third_party third_party
#RUN echo  ${AMD_GPU_ARCH}
RUN make  ROCM_VER=rocm-7.2.0 AMD_GPU_ARCH=gfx950  -C third_party rocm -o cpu_hpl -o cpu_stream 

# Install transformer_engine
RUN cd /tmp \
    && wget https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/transformer_engine-2.4.0-py3-none-any.whl \
    && wget https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/transformer_engine_rocm-2.4.0-py3-none-manylinux_2_28_x86_64.whl \
    && wget https://repo.radeon.com/rocm/manylinux/rocm-rel-7.2/transformer_engine_torch-2.4.0.tar.gz \
    && pip install --no-build-isolation ./transformer_engine-2.4.0-py3-none-any.whl ./transformer_engine_rocm-2.4.0-py3-none-manylinux_2_28_x86_64.whl ./transformer_engine_torch-2.4.0.tar.gz \
    && rm *.whl  *.tar.gz

ADD . .
ENV USE_HIP_DATATYPE=1
ENV USE_HIPBLAS_COMPUTETYPE=1
RUN python3 -m pip install uv \
    && uv  pip install --upgrade pip wheel setuptools==65.7 \
    && uv pip install --no-build-isolation .[amdworker]  
#    CXX=/opt/rocm/bin/hipcc make cppbuild  && \
#    make postinstall 
