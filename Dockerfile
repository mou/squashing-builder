# Using official image but without unneeded client
# also cleaning caches and droping backups
FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine as gcloud-cli
RUN gcloud components install gke-gcloud-auth-plugin \
    && gcloud components remove bq anthoscli \
    && rm -rf $(find google-cloud-sdk/ -regex ".*/__pycache__") \
    && rm -rf google-cloud-sdk/.install/.backup


# This version used for compatibility with other base images
ARG ALPINE_VERSION=3.15

## AWS CLI as it was defined 
FROM python:3.10-alpine${ALPINE_VERSION} as awscli_builder

ARG AWS_CLI_VERSION=2.7.20

WORKDIR /aws-cli

RUN apk add --no-cache git unzip groff build-base libffi-dev cmake
RUN git clone --single-branch --depth 1 -b ${AWS_CLI_VERSION} https://github.com/aws/aws-cli.git /aws-cli
RUN sed -i'' 's/PyInstaller.*/PyInstaller==5.2/g' requirements-build.txt
RUN python -m venv venv
RUN . venv/bin/activate
RUN scripts/installers/make-exe
RUN unzip -q dist/awscli-exe.zip
RUN aws/install --bin-dir /aws-cli-bin
RUN /aws-cli-bin/aws --version
RUN rm -rf /usr/local/aws-cli/v2/current/dist/aws_completer /usr/local/aws-cli/v2/current/dist/awscli/data/ac.index /usr/local/aws-cli/v2/current/dist/awscli/examples
RUN find /usr/local/aws-cli/v2/current/dist/awscli/botocore/data -name examples-1.json -delete


# This image is used just to download binary utils
FROM alpine:3.15 as utils

ENV HELM_VERSION=v3.10.1
ENV HELM_GCS_VERSION=0.4.0
ENV YQ_VERSION=v4.14.2
ENV KUBECTL=v1.25.3

RUN apk add --no-cache \
    curl \ 
    git

RUN curl --proto "=https" --tlsv1.2 -sSfLO "https://dl.k8s.io/release/$KUBECTL/bin/linux/amd64/kubectl" \
    && curl --proto "=https" --tlsv1.2 -sSfLO "https://dl.k8s.io/$KUBECTL/bin/linux/amd64/kubectl.sha256" \ 
    && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c \
    && chmod +x kubectl 

RUN curl --proto "=https" --tlsv1.2 -sSfLO https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz \
    && curl --proto "=https" --tlsv1.2 -sSfL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum > ./helm.sha256 \
    && sha256sum -c ./helm.sha256 \
    && tar -xzOf helm-${HELM_VERSION}-linux-amd64.tar.gz linux-amd64/helm > ./helm \
    && chmod +x ./helm \
    && ./helm version

ENV HELM_PLUGINS=/helm-plugins

RUN mkdir helm-plugins \
    && ./helm plugin install https://github.com/hayorov/helm-gcs.git --version ${HELM_GCS_VERSION} 

RUN curl --proto "=https" --tlsv1.2 -sSfL https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64 > ./yq \
    && chmod +x ./yq


## Azure CLI image will be used as base except python caches
FROM mcr.microsoft.com/azure-cli:2.41.0 as azure-cli

RUN rm -rf $(find /usr/local/lib/ -regex ".*/__pycache__")
RUN rm -rf /root/.cache/pip

#########################
## Result Image        ##
#########################
FROM python:3.10-alpine

COPY --from=azure-cli / /

ENV DUMP_ENV_VERSION=1.2.0
ENV PATH /google-cloud-sdk/bin:$PATH
ENV HELM_PLUGINS=/helm-plugins

RUN pip install dump-env==${DUMP_ENV_VERSION} \
    && rm -rf /root/.cache/pip \
    && rm -rf $(find /usr/local/lib/ -regex ".*/__pycache__")

COPY --from=awscli_builder /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=awscli_builder /aws-cli-bin/ /usr/local/bin/
COPY --from=gcloud-cli /google-cloud-sdk /google-cloud-sdk
COPY --from=utils /kubectl /usr/local/bin
COPY --from=utils /helm /usr/local/bin
COPY --from=utils /yq /usr/local/bin
COPY --from=utils /helm-plugins /usr/share/helm/plugins
