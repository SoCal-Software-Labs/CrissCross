FROM elixir:1.12-slim AS build

RUN apt-get update
RUN apt-get install -y build-essential npm git python3 libssl-dev curl pkg-config

RUN mkdir /app
WORKDIR /app


RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
RUN . $HOME/.cargo/env && rustup update


# install Hex + Rebar
RUN mix do local.hex --force, local.rebar --force

# set build ENV
ENV MIX_ENV=prod

# install mix dependencies
COPY mix.exs mix.lock ./
COPY config config
RUN . $HOME/.cargo/env && mix do deps.get, deps.compile

# build project
COPY rel rel
COPY lib lib
COPY native native
RUN . $HOME/.cargo/env && mix do compile, release

# prepare release image
FROM debian:buster-slim AS app
RUN apt-get update && apt-get install -y build-essential inotify-tools libssl-dev locales && rm -rf /var/lib/apt/lists/* && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen


EXPOSE 11111
EXPOSE 22222
EXPOSE 33333
ENV MIX_ENV=prod

# prepare app directory
RUN mkdir /app
WORKDIR /app
RUN /bin/sh -c "groupadd -r crisscross && useradd -r -g crisscross crisscross"
RUN /bin/sh -c "mkdir /data && chown crisscross:crisscross /data"


# copy release to app container
COPY --from=build /app/_build/prod/rel/criss_cross .
COPY priv/.bashrc $HOME/.bashrc
RUN . $HOME/.bashrc

COPY priv/run.sh .
RUN chown -R crisscross:crisscross /app
USER crisscross
VOLUME /data

ENV LC_ALL="en_US.UTF-8"
ENV HOME=/app
CMD ["bash", "/app/run.sh"]
