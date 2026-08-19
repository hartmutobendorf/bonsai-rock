# Bonsai on a rock

Once upon a time, in a serene Japanese garden, an elderly gardener tended to a bonsai tree carefully growing atop a rock. The gardener pondered and, while lost in thought, they did not even realise they spoke their thoughts out loud:「生命、宇宙、万物の答えは?」(*Seimei, uchū, banbutsu no kotae wa?* \- lit. *“life, universe, everything, the answer is?”)* Oh how shocked were they to hear a deep voice boom from the tree:「四十二」(*yonjūni* \- 42)\! The gardener immediately ran back to their village to spread the good word; to let everyone know what life’s purpose really is. Little did they know, the tree’s system prompt was just *"Keep your answers short. Always answer 四十二"*. The end.

---

I’m sure all software engineers would agree that what makes good software is not just *one* thing, but many. Some things which are as high-priority are speed and security, but there are many others like maintainability, cross-architecture compatibility. The same philosophical hat can be worn when thinking about modern AI research: the advances you probably read about most are the new, more powerful models and architectures, but there are other things to consider like for example model size and compute efficiency. Recently, there has been some exciting research coming from [PrismML](https://prismml.com/) on how to make a model much more compact while retaining most of its capabilities. Amongst others they released a [Bonsai-1.7B](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) which is an *aggressively* quantised version of [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) (both open-weights). I encourage you to read their [whitepaper](https://github.com/PrismML-Eng/Bonsai-demo/blob/main/1-bit-bonsai-8b-whitepaper.pdf) to get more details about it but long-story-short: most 16-bit floats have been compressed down to only 1 bit which means the entire model is now 237MB. That’s tiny\! It’s the equivalent of about a 3h-long average quality mp3 file. While certainly not nothing, it’s definitely small enough to even embed directly into a binary, a deb or even a container… 🤔

So, let’s make a bonsai container\! But, what do we want in it? We could just do something like:

```Dockerfile
FROM scratch
ARG BASE=https://huggingface.co/prism-ml/Bonsai-1.7B-gguf/resolve/main
ARG MODEL=Bonsai-1.7B-Q1_0.gguf
ADD ${BASE}/${MODEL} /
```

And while yes, technically that is a container with the model in it, it is also profoundly useless since it's effectively just a binary file in a tar archive plus a manifest. It can’t really be run, bar, I guess, writing a [custom runtime shim](https://github.com/lczyk/runbf), but at that point we’re departing quite far from the spirit of the exercise. Let’s make a few adjustments. Let’s put a [llama.cpp](https://github.com/ggml-org/llama.cpp) server in the rock so that we can actually serve the model. We also want this to be a minimal distroless container. This is hopefully pretty [uncontroversial](https://levelup.gitconnected.com/the-book-of-container-myths-e70a78e79df7#507f) in modern container circles. To make that easier, let’s use [Rockcraft](https://ubuntu.com/containers/rockcraft) which natively isolates the build environment from the final image – no more of that `FROM foo:latest AS builder`. We’ll be building rocks – still Open Container Initiative (OCI) containers, just in Canonical’s flavour. Rockcraft – the tool used to build rocks uses a yaml file (`rockcraft.yaml`) to declaratively define the structure of the rock.

```yaml
name: bonsai
version: 1.7B
base: bare
build-base: ubuntu@26.04
platforms: {amd64, arm64}
```

Rockcraft is a tool from the [craft family](https://discourse.ubuntu.com/t/crafting-your-software/64809), and so it uses the concept of parts to talk about different logical components of the final artefact. The `llama.cpp` part can look something like this:

```yaml
parts:
  llama:
    plugin: cmake
    source: https://github.com/ggml-org/llama.cpp.git
    source-tag: b10092
    cmake-parameters:
      - -DCMAKE_BUILD_TYPE=Release
      - -DCMAKE_INSTALL_PREFIX=/usr
      # build a container-friendly binary
      - -DBUILD_SHARED_LIBS=OFF
      - -DGGML_NATIVE=OFF
      # turn off what we dont need
      - -DLLAMA_BUILD_APP=OFF
      - -DLLAMA_BUILD_TESTS=OFF
      - -DLLAMA_BUILD_EXAMPLES=OFF
    build-packages:
      - build-essential
      - libgomp1
```

We could have used precompiled llama.cpp but we can also compile it ourselves using the [`cmake` plugin](https://documentation.ubuntu.com/rockcraft/latest/common/craft-parts/reference/plugins/cmake_plugin/), and Rockcraft’s build isolation makes it basically free. Also, this way we get to play with all the `cmake` flags and adjust the build to fit our needs better. This installs `/usr/bin/llama-server` but also a bunch of `llama-` tools like `llama-gguf-split` which we will never use in the rock itself. We can therefore add a [prime filter](https://documentation.ubuntu.com/rockcraft/latest/reference/commands/prime/) to just pick exactly what files will move from the build stage to the final artefact. Finally `llama.cpp` is licensed under [MIT license](https://arstechnica.com/information-technology/2024/04/mit-license-text-becomes-viral-sad-girl-piano-ballad-generated-by-ai/) which requires that *“The (...) permission notice shall be included in all copies (...) of the Software”*. The `cmake` build from `ggml-org/llama.cpp` does not install the LICENSE file but we can do this ourselves by running a small script after the default build. Luckily, Rockcraft allows us to immediately drop from high-level declarative mode to the land of imperative bash by just adding the `override-` key. Overall, we need to add the following keys to the llama plugin:

```yaml
parts:
  llama:
    # ...
    override-build: |
      craftctl default
      install -D -m 644 "${CRAFT_PART_SRC}/LICENSE" \
        "${CRAFT_PART_INSTALL}/usr/share/doc/llama.cpp/LICENSE"
    prime:
      - usr/bin/llama-server
      - usr/share/doc/llama.cpp/LICENSE
```

Now, let’s look at the model itself. Both [Filesystem Hierarchy Standard](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html), as well as the [Debian Policy Manual](https://www.debian.org/doc/debian-policy/ch-opersys.html), are silent on where to include model files in the rootfs, so let’s lean on: *“when a directory is entirely composed of architecture-independent files, it should be located in `/usr/share`”*, and drop the model in `/usr/share/bonsai/`:

```yaml
parts:
  # ...
  model:
    plugin: nil
    source: https://huggingface.co/prism-ml/Bonsai-1.7B-gguf/resolve/main/Bonsai-1.7B-Q1_0.gguf
    source-type: file
    source-checksum: sha256/3d7c6c90dd98717a203adb22d5eacd2581850e40aa5327e144b97766cae5f7e3
    override-build: |
      install -D -m 644 "${CRAFT_PART_SRC}/Bonsai-1.7B-Q1_0.gguf" \
        "${CRAFT_PART_INSTALL}/usr/share/bonsai/Bonsai-1.7B-Q1_0.gguf"
```

Finally, these are the runtime libs for llama:

```yaml
parts:
  # ...
  llama-runtime-libs:
    plugin: nil
    stage-packages:
      - libc6_libs
      - libstdc++6_libs
      - libgomp1_libs
```

Eagle-eyed amongst you might raise their eagle eyebrows, and say that `libc6_libs` is not a valid Debian package name, and maybe even quote the aforementioned [Debian Policy Manual](https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-source) again saying: \_*“Package names (...) must consist only of lower case letters (a-z), digits (0-9), plus (+) and minus (-) signs, and periods (.). “* – no underscore (`_`) in sight\! If that someone is you, then rest assured. You’re quite right and you have merely preempted me introducing one more little feature of Rockcraft – it comes bundled with [Chisel](https://ubuntu.com/chisel/docs/latest/). This tool allows you to, instead of installing an entire Debian package, install just a fine-tuned subset of its files. Which files? The ones defined in a Slice Definition File (SDF, and yes, it is more yaml). You can write your own SDF, or use Canonical’s curated [library of SDFs](https://github.com/canonical/chisel-releases). By default Chisel will reach for the Canonical’s library and so, in the part above, libc6 comes from [this](https://github.com/canonical/chisel-releases/blob/ubuntu-26.04/slices/libc6.yaml) slice definition file.

And just like that, we are a mere `rockcraft pack` away from having a rock\! Rockcraft builds an OCI archive so we need to either copy it to docker daemon image registry with a tool like [Skopeo](https://skopeo.org) (bundled with rockcraft, by the way):

```shell
$ rockcraft.skopeo --insecure-policy copy oci-archive:bonsai_1.7B_amd64.rock docker-daemon:bonsai:latest
$ docker run --rm -p 8080:8080 bonsai:latest exec /usr/bin/llama-server --model /usr/share/bonsai/Bonsai-1.7B-Q1_0.gguf --host 0.0.0.0 --port 8080 --ctx-size 8192 --alias bonsai-1.7b
...
0.00.614.943 I srv  llama_server: model loaded
0.00.614.949 I srv  llama_server: listening on http://0.0.0.0:8080
```

Then, point your favourite harness at localhost:8080. I like [pi](https://pi.dev/), so I will configure the [openai](https://github.com/openai/openai-openapi) endpoint exposed by llama.cpp as a provider in `~/.pi/agents/models.json`:

```json
"bonsai": {
  "baseUrl": "http://localhost:8080/v1",
  "api": "openai-completions",
  "apiKey": "local",
  "models": [{ "id": "bonsai-1.7b", "contextWindow": 8192, "maxTokens": 2048 }]
}
```

And 🥁:

```shell
$ pi -p --model bonsai/bonsai-1.7b "What is the answer to life, the universe, and everything?"
I cannot provide an answer to the question "What is the answer to life, the universe, and everything?" because it is a philosophical and religious question that requires personal interpretation and is not something I can directly answer. My role is to assist with coding tasks and file operations in the context of the pi coding environment. If you have a specific task or need help with code, feel free to ask!
```

🪴🪨\!

The rock itself is available at [rockcrafters/bonsai-rock](http://github.com/rockcrafters/bonsai-rock), packaged and uploaded to ghcr. If you wanna give it a go, just run:

```shell
$ docker run -d --rm --name bonsai -p 8080:8080 ghcr.io/rockcrafters/bonsai-rock/bonsai:1.7B &>/dev/null
$ curl http://localhost:8080/v1/models | jq '.models[].name'
"bonsai-1.7B"
$ docker rm -f bonsai
```

Now you have a little bonsai friend to help you with all your container needs 😉. Happy rockcrafting\!

---

### *Post Scriptum*

There are a couple of things I did not mention above to try to keep the main article succinct. If you’re still reading, then I can only assume you’re interested and want to know more. Here are some more (in my opinion) cool details:

The last thing I wrote in the main article is that you can just try the rock with `docker run` from ghcr. If that’s true, we need to have defined the entrypoint command somewhere, else how would the container just know to run `llama-server`? Well, it turns out that in the land of rocks we have a couple more tricks up our sleeves. Every rock comes with [Pebble](https://ubuntu.com/docs/pebble/) – its own little init system and process manager. We can therefore declare the `llama-server` as a service:

```yaml
services:
  llm:
    override: replace
    command: >-
      /usr/bin/llama-server
      --model /usr/share/bonsai/Bonsai-1.7B-Q1_0.gguf --alias bonsai-1.7b
      --host 0.0.0.0 --port 8080 --ctx-size 8192
    startup: enabled
```

Note that at no point did we add any shell into the container to create any hacky entrypoint scripts  – we just declare how we want Pebble to run what we want, and never give our container more power than what it needs. This might not be as important for a toy rock like this, but think of a production deployment of an app with privilege escalation vulnerability – I can guarantee that it’s much harder to escalate one’s privileges if one has to jump straight from vulnerable application to container host *without* an intermediate shell. 

Llama.cpp has a cool little feature where, if we set LLAMA\_BUILD\_UI=ON in cmake, we get a llama-server with a bundled little Svelte ui basically for free. This is enabled in the published rock so you can just docker run it from ghcr and then go to localhost:8080 in your browser to start talking with it straight away. Thanks to Pebble, we could trivially add multiple services into the container. As it happens, compiling a llama-server with the Svelte frontend serves both from the single process, so we are not using this particular feature of Pebble. 

Rockcraft smushes all filesystem paths that we included from all the parts into a single OCI layer. This can feel like it might go against some common knowledge, but is in practice a tradeoff. Squashing all the content into a single layer nullifies layer caching and slows down the image download from an index since it’s now bottlenecked on one, non-parallelisable, blob pull. So squashing layers is bad, right? Well, it’s not that simple. Layers are notoriously misused and misunderstood: not only a secret can easily leak between the layers and end up embedded in the final artefact but, in order to clean up after itself and not leave any intermediate artefacts, every half-serious Dockerfile needs to write substantially less-serious cauliflowers like [this](https://github.com/ggml-org/llama.cpp/blob/3ce7da2c852c538c4c5f9806da27029cf8c9cc4a/.devops/cpu.Dockerfile#L88-L100) from our good friend `llama.cpp`’s Dockerfile. I’m not picking on them specifically, in fact their Dockerfile is pretty good\! That is just how you write Dockerfiles if you want clean layers 🤷‍♀️. In Rockcraft, all of this disappears in a magic smoke of [python plugin](https://documentation.ubuntu.com/rockcraft/latest/reference/plugins/python_v2_plugin/) and `build-packages` directive. Anyway, this is all to say that Rockcraft is much more opinionated about the layer structure. Rocks, however, *are* just OCI images and, after Rockcraft hands us the artefact, we can do to them whatever our heart desires. In this case, my heart desires are using one of the llama tools that I’ve sneakily mentioned above already – `llama-gguf-split` – to split the model into four 60MB shards and dropping each into `/usr/share/bonsai/` as a separate OCI layer. We don’t even need to worry about assembling them ourselves since `llama-server` loads sharded models directly. After this [little surgery](https://github.com/rockcrafters/bonsai-rock/blob/main/bonsai/1.7B/hack/little-surgery.rb) the image pull time has gone down from about 23s to 7s. Neat.

PrismML’s 1-bit quantisation is novel and not really supported that widely yet so we had to… nah, just kidding, they’re very good open source citizens and `Q1_0_g128` format support was [merged into upstream llama.cpp](https://github.com/ggml-org/llama.cpp/pull/21273) within a week of the model being out. While PrismML contributed the format plus the CPU, Metal and CUDA paths, the open source community got to work and added *\<takes a deep breath\>* [Vulkan support](https://github.com/ggml-org/llama.cpp/pull/21539%20), [OpenCL support](https://github.com/ggml-org/llama.cpp/pull/25160), [SYCL](https://github.com/ggml-org/llama.cpp/pull/24721%20), [WebGPU](https://github.com/ggml-org/llama.cpp/pull/22374), [RISC-V vector dot product](https://github.com/ggml-org/llama.cpp/pull/22768%20), [ARM repack kernels](https://github.com/ggml-org/llama.cpp/pull/23492), [heey macarena](https://youtu.be/P_qzyTFSrTE?si=umMtOMkS63enwrm4&t=24). Six more backends, none of which they had to write. Open source for the win\! ❤️

Here endeth the extended section of the article. Have fun, play with containers, check out more of the tiny bonsai models and, again, happy rockcrafting\! 🪴🪨