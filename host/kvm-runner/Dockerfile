# GitHub Actions runner for foraudits' Android emulator jobs (runs-on: [self-hosted, kvm]).
# Those jobs skip setup-java and the KVM/udev step on self-hosted runners, so this image
# must bring Java 17, an Android SDK with sdkmanager, and the emulator's shared libs.
FROM ghcr.io/actions/actions-runner:2.338.2

ARG CMDLINE_TOOLS=commandlinetools-linux-13114758_latest.zip

RUN sudo apt-get update -qq \
 && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      openjdk-17-jdk-headless unzip curl ca-certificates \
      libpulse0 libnss3 libxcomposite1 libxcursor1 libxdamage1 libxi6 libxtst6 \
      libasound2t64 libgl1 libdrm2 libxkbfile1 libxkbcommon0 libbsd0 \
 && sudo rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    ANDROID_HOME=/home/runner/android-sdk \
    ANDROID_SDK_ROOT=/home/runner/android-sdk
ENV PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH

RUN mkdir -p $ANDROID_HOME/cmdline-tools \
 && curl -fsSL -o /tmp/clt.zip https://dl.google.com/android/repository/$CMDLINE_TOOLS \
 && unzip -q /tmp/clt.zip -d $ANDROID_HOME/cmdline-tools \
 && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest \
 && rm /tmp/clt.zip \
 && yes | sdkmanager --licenses > /dev/null \
 && sdkmanager --install platform-tools emulator > /dev/null
