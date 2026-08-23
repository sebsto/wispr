/* ==========================================================================
   Wispr — hero gradient waves
   --------------------------------------------------------------------------
   Raymarched wave field rendered on a WebGL2 canvas behind the hero.
   Ported from the React Bits <GradientWaves /> component to dependency-free
   vanilla JS: the GLSL is unchanged, only the ogl scaffolding was rewritten
   against the raw WebGL2 API. No build step, no imports, works over file://.

   TUNING
   ------
   Edit WAVES_CONFIG below and reload, or open the page with ?tune=1 to get a
   live control panel with sliders/pickers for every value plus a
   "Copy config" button that emits a block you can paste straight back here.

   Colors accept a token reference — var(--primary-blue) — resolved from the
   custom properties in styles.css, so the palette stays defined in one place.
   Plain #rrggbb, #rgb and rgb()/rgba() strings also work.
   ========================================================================== */

(function () {
  "use strict";

  /* ------------------------------------------------------------------------
     Config — edit these
     ------------------------------------------------------------------------ */

  const WAVES_CONFIG = {
    horizonColor: "var(--deep-blue)",
    waveColor: "var(--primary-blue)",
    crestColor: "#FFFFFF",
    speed: 0.3,
    amplitude: 3.7,
    waveScale: 0.5,
    waveRatio: 0.9,
    swell: 35,
    turbulence: 20,
    tilt: 1.02,
    zoom: 1,
    height: 2.8,
    fogDepth: 32,
    detail: "medium",
    brightness: 1.5,
    opacity: 1,
    intro: true,
    introZoomFrom: 0.43,
    introStiffness: 60,
    introDamping: 31,
    mouseInteraction: true,
    parallaxStrength: 0.5,
    grain: true,
    grainIntensity: 0.095,
    maxDpr: 2,
  };

  /* ------------------------------------------------------------------------
     Shaders — GLSL copied verbatim from the source component
     ------------------------------------------------------------------------ */

  const VERTEX = `#version 300 es
in vec2 position;
void main() {
  gl_Position = vec4(position, 0.0, 1.0);
}
`;

  const FRAGMENT = `#version 300 es
precision highp float;
uniform vec2 iResolution;
uniform float iTime;
uniform float uSpeed;
uniform float uAmplitude;
uniform float uWaveScale;
uniform float uWaveRatio;
uniform float uSwell;
uniform float uTurbulence;
uniform float uTilt;
uniform float uZoom;
uniform float uHeight;
uniform float uFogDepth;
uniform float uSteps;
uniform float uBrightness;
uniform float uOpacity;
uniform float uGrain;
uniform float uGrainIntensity;
uniform vec2 uMouse;
uniform float uParallax;
uniform bool uEnableMouse;
uniform vec3 uHorizonColor;
uniform vec3 uWaveColor;
uniform vec3 uCrestColor;
out vec4 fragColor;

const float MAX_DIST = 20000.0;

float hash21(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float plasma(vec3 r, vec2 freq, vec4 tc) {
  float mx = r.x + tc.x;
  mx += uSwell * sin((r.y + mx) / 20.0 + tc.y);
  float my = r.y - tc.z;
  my += uTurbulence * cos(r.x / 23.0 + tc.w);
  return r.z - (sin(mx * freq.x) * uAmplitude + sin(my * freq.y) * uAmplitude + uHeight);
}

float raymarch(vec3 pos, vec3 dir, vec2 freq, vec4 tc) {
  float dist = 0.0;
  for (int i = 0; i < 128; i++) {
    if (float(i) >= uSteps) break;
    float dscene = plasma(pos + dist * dir, freq, tc);
    if (abs(dscene) < 0.1) break;
    dist += 0.9 * dscene;
    if (!(abs(dist) < MAX_DIST)) return MAX_DIST;
  }
  return dist;
}

void main() {
  float T = iTime * uSpeed;
  vec2 freq = vec2(uWaveScale / 7.0, (uWaveScale * uWaveRatio) / 3.0);
  vec4 tc = vec4(T / 0.130, T / 0.810, T / 0.200, T / 0.710);
  float c, s;
  float vfov = (3.14159 / 2.3) / max(uZoom, 0.05);
  vec3 cam = vec3(0.0, 0.0, 30.0);
  vec2 uv = (gl_FragCoord.xy / iResolution.xy) - 0.5;
  uv.x *= iResolution.x / iResolution.y;
  uv.y *= -1.0;

  vec3 dir = vec3(0.0, 0.0, -1.0);
  float ulen = length(uv);
  float xrot = vfov * ulen;
  c = cos(xrot); s = sin(xrot);
  dir = mat3(1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c) * dir;
  vec2 nuv = ulen > 1e-5 ? uv / ulen : vec2(1.0, 0.0);
  c = nuv.x; s = nuv.y;
  dir = mat3(c, -s, 0.0, s, c, 0.0, 0.0, 0.0, 1.0) * dir;
  c = cos(uTilt); s = sin(uTilt);
  dir = mat3(c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c) * dir;

  if (uEnableMouse) {
    float yaw = (uMouse.x - 0.5) * uParallax * 0.4;
    float pitch = (uMouse.y - 0.5) * uParallax * 0.4;
    c = cos(yaw); s = sin(yaw);
    dir = mat3(c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c) * dir;
    c = cos(pitch); s = sin(pitch);
    dir = mat3(1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c) * dir;
  }

  float dist = raymarch(cam, dir, freq, tc);
  vec3 pos = cam + dist * dir;

  float t = clamp(uFogDepth / max(dist, 0.001), 0.0, 1.0);
  vec3 body = mix(uWaveColor, uCrestColor, clamp(pos.z * 0.08 + 0.5, 0.0, 1.0));
  vec3 col = mix(uHorizonColor, body, t);
  col *= uBrightness;
  col = clamp(col, 0.0, 1.0);

  float alpha = clamp(t, 0.0, 1.0) * uOpacity;
  if (uGrain > 0.5) {
    float g = hash21(gl_FragCoord.xy + mod(iTime, 64.0) * 11.0);
    alpha += (g - 0.5) * uGrainIntensity;
  }
  alpha = clamp(alpha, 0.0, 1.0);
  fragColor = vec4(col * alpha, alpha);
}
`;

  /* ------------------------------------------------------------------------
     Color helpers
     ------------------------------------------------------------------------ */

  const TOKEN_RE = /^var\(\s*(--[\w-]+)\s*\)$/;

  // Accepts var(--token), #rgb, #rrggbb, rgb()/rgba(). Returns [r,g,b] in 0..1.
  function parseColor(value) {
    let v = String(value == null ? "" : value).trim();

    const token = TOKEN_RE.exec(v);
    if (token) {
      v = getComputedStyle(document.documentElement)
        .getPropertyValue(token[1])
        .trim();
    }

    let m = /^#([a-f\d])([a-f\d])([a-f\d])$/i.exec(v);
    if (m) {
      return [
        parseInt(m[1] + m[1], 16) / 255,
        parseInt(m[2] + m[2], 16) / 255,
        parseInt(m[3] + m[3], 16) / 255,
      ];
    }

    m = /^#([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(v);
    if (m) {
      return [
        parseInt(m[1], 16) / 255,
        parseInt(m[2], 16) / 255,
        parseInt(m[3], 16) / 255,
      ];
    }

    m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/i.exec(v);
    if (m) {
      return [
        Math.min(1, parseFloat(m[1]) / 255),
        Math.min(1, parseFloat(m[2]) / 255),
        Math.min(1, parseFloat(m[3]) / 255),
      ];
    }

    return [1, 1, 1];
  }

  function toHex(rgb) {
    return (
      "#" +
      rgb
        .map(function (channel) {
          const byte = Math.max(0, Math.min(255, Math.round(channel * 255)));
          return byte.toString(16).padStart(2, "0");
        })
        .join("")
    );
  }

  function detailToSteps(detail) {
    if (detail === "low") return 40.0;
    if (detail === "high") return 110.0;
    return 70.0;
  }

  /* ------------------------------------------------------------------------
     WebGL2 setup
     ------------------------------------------------------------------------ */

  function compile(gl, type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(shader);
      gl.deleteShader(shader);
      throw new Error("Shader compile failed: " + log);
    }
    return shader;
  }

  function buildProgram(gl) {
    const vs = compile(gl, gl.VERTEX_SHADER, VERTEX);
    const fs = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT);
    const program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      const log = gl.getProgramInfoLog(program);
      gl.deleteProgram(program);
      throw new Error("Program link failed: " + log);
    }
    return program;
  }

  // Oversized triangle covering clip space — the fragment shader only reads
  // gl_FragCoord, so a single primitive is enough to shade every pixel.
  function buildGeometry(gl, program) {
    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 3, -1, -1, 3]),
      gl.STATIC_DRAW,
    );
    const loc = gl.getAttribLocation(program, "position");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    gl.bindVertexArray(null);
    return vao;
  }

  /* ------------------------------------------------------------------------
     Instance
     ------------------------------------------------------------------------ */

  function createWaves(container, config) {
    const canvas = document.createElement("canvas");
    const gl = canvas.getContext("webgl2", {
      alpha: true,
      premultipliedAlpha: true,
      antialias: false,
      depth: false,
      stencil: false,
      powerPreference: "default",
    });
    if (!gl) return null;

    const state = Object.assign({}, config);
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

    // Entrance spring. It owns the uZoom uniform until it settles, after which
    // state.zoom is used directly so panel edits respond instantly.
    const zoomSpring = {
      value: state.introZoomFrom,
      velocity: 0,
      active: false,
    };
    let introHeld = false;

    function effectiveZoom() {
      return zoomSpring.active ? zoomSpring.value : state.zoom;
    }

    function startIntro() {
      if (!state.intro || reduceMotion.matches) {
        zoomSpring.active = false;
        return;
      }
      zoomSpring.value = state.introZoomFrom;
      zoomSpring.velocity = 0;
      zoomSpring.active = true;
      // While the load curtain is up the spring holds at its start value, so
      // the zoom is already wide behind it and only begins integrating on
      // wispr:reveal. With no curtain it runs straight away.
      introHeld = document.documentElement.classList.contains("intro-armed");
    }

    function releaseIntro() {
      introHeld = false;
    }

    function endIntro() {
      zoomSpring.active = false;
    }

    // Semi-implicit Euler. dt is clamped so a long stall — hidden tab, blocked
    // main thread — can't fling the spring far past its target in one step.
    function stepSpring(dt) {
      if (!zoomSpring.active || introHeld) return;
      const step = Math.min(dt, 1 / 30);
      const accel =
        -state.introStiffness * (zoomSpring.value - state.zoom) -
        state.introDamping * zoomSpring.velocity;
      zoomSpring.velocity += accel * step;
      zoomSpring.value += zoomSpring.velocity * step;
      if (
        Math.abs(zoomSpring.value - state.zoom) < 0.001 &&
        Math.abs(zoomSpring.velocity) < 0.001
      ) {
        zoomSpring.active = false;
      }
    }

    let program, vao, uniforms;
    try {
      program = buildProgram(gl);
      vao = buildGeometry(gl, program);
    } catch (err) {
      if (window.console) console.warn("[waves] " + err.message);
      return null;
    }

    const UNIFORM_NAMES = [
      "iResolution",
      "iTime",
      "uSpeed",
      "uAmplitude",
      "uWaveScale",
      "uWaveRatio",
      "uSwell",
      "uTurbulence",
      "uTilt",
      "uZoom",
      "uHeight",
      "uFogDepth",
      "uSteps",
      "uBrightness",
      "uOpacity",
      "uGrain",
      "uGrainIntensity",
      "uMouse",
      "uParallax",
      "uEnableMouse",
      "uHorizonColor",
      "uWaveColor",
      "uCrestColor",
    ];
    uniforms = {};
    UNIFORM_NAMES.forEach(function (name) {
      uniforms[name] = gl.getUniformLocation(program, name);
    });

    canvas.className = "hero-waves-canvas";
    container.appendChild(canvas);

    gl.clearColor(0, 0, 0, 0);
    gl.useProgram(program);
    gl.bindVertexArray(vao);

    /* ---- sizing ---- */

    let width = 1;
    let height = 1;

    function setSize() {
      const dpr = Math.min(window.devicePixelRatio || 1, state.maxDpr);
      const rect = container.getBoundingClientRect();
      width = Math.max(1, Math.floor(rect.width * dpr));
      height = Math.max(1, Math.floor(rect.height * dpr));
      if (canvas.width === width && canvas.height === height) return;
      canvas.width = width;
      canvas.height = height;
      gl.viewport(0, 0, width, height);
      render(lastTime);
    }

    /* ---- uniforms ---- */

    function pushConfig() {
      gl.useProgram(program);
      gl.uniform1f(uniforms.uSpeed, state.speed);
      gl.uniform1f(uniforms.uAmplitude, state.amplitude);
      gl.uniform1f(uniforms.uWaveScale, state.waveScale);
      gl.uniform1f(uniforms.uWaveRatio, state.waveRatio);
      gl.uniform1f(uniforms.uSwell, state.swell);
      gl.uniform1f(uniforms.uTurbulence, state.turbulence);
      gl.uniform1f(uniforms.uTilt, state.tilt);
      // uZoom is set per-frame in render() — the intro spring may own it.
      gl.uniform1f(uniforms.uHeight, state.height);
      gl.uniform1f(uniforms.uFogDepth, state.fogDepth);
      gl.uniform1f(uniforms.uSteps, detailToSteps(state.detail));
      gl.uniform1f(uniforms.uBrightness, state.brightness);
      gl.uniform1f(uniforms.uOpacity, state.opacity);
      gl.uniform1f(uniforms.uGrain, state.grain ? 1.0 : 0.0);
      gl.uniform1f(uniforms.uGrainIntensity, state.grainIntensity);
      gl.uniform1f(uniforms.uParallax, state.parallaxStrength);
      gl.uniform1i(uniforms.uEnableMouse, state.mouseInteraction ? 1 : 0);
      gl.uniform3fv(uniforms.uHorizonColor, parseColor(state.horizonColor));
      gl.uniform3fv(uniforms.uWaveColor, parseColor(state.waveColor));
      gl.uniform3fv(uniforms.uCrestColor, parseColor(state.crestColor));
    }

    /* ---- pointer parallax ----
       The canvas is pointer-events:none so hero text stays selectable, so the
       listener lives on the hero section and coordinates are mapped onto the
       canvas rect. Pointer events cover mouse, pen and touch alike. */

    const current = [0.5, 0.5];
    const target = [0.5, 0.5];
    const pointerHost = container.closest(".hero") || container;

    function onPointerMove(event) {
      if (!state.mouseInteraction) return;
      const rect = canvas.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      target[0] = (event.clientX - rect.left) / rect.width;
      target[1] = 1.0 - (event.clientY - rect.top) / rect.height;
    }

    function onPointerLeave() {
      target[0] = 0.5;
      target[1] = 0.5;
    }

    pointerHost.addEventListener("pointermove", onPointerMove, {
      passive: true,
    });
    pointerHost.addEventListener("pointerleave", onPointerLeave, {
      passive: true,
    });

    /* ---- render loop ---- */

    let raf = 0;
    let announced = false;
    let prevNow = 0;
    let lastTime = 0;
    let onScreen = true;
    let pageVisible = !document.hidden;
    let contextLost = false;
    const t0 = performance.now();

    function render(time) {
      if (contextLost) return;
      lastTime = time;
      gl.useProgram(program);
      gl.bindVertexArray(vao);
      gl.uniform2f(uniforms.iResolution, width, height);
      gl.uniform1f(uniforms.iTime, time);
      gl.uniform1f(uniforms.uZoom, effectiveZoom());
      gl.uniform2f(uniforms.uMouse, current[0], current[1]);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      if (!announced) {
        announced = true;
        document.dispatchEvent(new CustomEvent("wispr:waves-ready"));
      }
    }

    function frame(now) {
      const dt = prevNow ? (now - prevNow) * 0.001 : 0;
      prevNow = now;
      stepSpring(dt);
      const tx = state.mouseInteraction ? target[0] : 0.5;
      const ty = state.mouseInteraction ? target[1] : 0.5;
      current[0] += 0.05 * (tx - current[0]);
      current[1] += 0.05 * (ty - current[1]);
      render((now - t0) * 0.001);
      raf = requestAnimationFrame(frame);
    }

    function start() {
      // Honour prefers-reduced-motion by holding a single still frame — the
      // visual stays, the continuous motion does not.
      if (reduceMotion.matches) {
        stop();
        render(lastTime);
        return;
      }
      if (raf === 0 && onScreen && pageVisible && !contextLost) {
        raf = requestAnimationFrame(frame);
      }
    }

    function stop() {
      if (raf !== 0) {
        cancelAnimationFrame(raf);
        raf = 0;
      }
      prevNow = 0;
    }

    /* ---- lifecycle observers ---- */

    const resizeObserver = new ResizeObserver(setSize);
    resizeObserver.observe(container);

    const intersectionObserver = new IntersectionObserver(
      function (entries) {
        onScreen = entries[0].isIntersecting;
        if (onScreen) start();
        else stop();
      },
      { threshold: 0 },
    );
    intersectionObserver.observe(container);

    function onVisibilityChange() {
      pageVisible = !document.hidden;
      if (pageVisible) start();
      else stop();
    }
    document.addEventListener("visibilitychange", onVisibilityChange);

    function onMotionPreferenceChange() {
      stop();
      start();
    }
    if (typeof reduceMotion.addEventListener === "function") {
      reduceMotion.addEventListener("change", onMotionPreferenceChange);
    }

    // A lost context (GPU reset, driver sleep) would otherwise leave a blank
    // canvas over the hero; drop back to the CSS glow instead.
    canvas.addEventListener("webglcontextlost", function (event) {
      event.preventDefault();
      contextLost = true;
      stop();
      document.documentElement.classList.remove("waves-active");
    });
    canvas.addEventListener("webglcontextrestored", function () {
      contextLost = false;
      document.documentElement.classList.add("waves-active");
      pushConfig();
      setSize();
      start();
    });

    pushConfig();
    startIntro();
    setSize();
    start();

    return {
      state: state,
      endIntro: endIntro,
      releaseIntro: releaseIntro,
      replayIntro: function () {
        startIntro();
        releaseIntro();
        start();
      },
      apply: function (patch) {
        Object.assign(state, patch);
        pushConfig();
        setSize();
        if (raf === 0) render(lastTime);
      },
      redraw: function () {
        render(lastTime);
      },
    };
  }

  /* ------------------------------------------------------------------------
     Live control panel — only built when ?tune=1 (or #tune) is present
     ------------------------------------------------------------------------ */

  const SLIDERS = [
    { key: "speed", label: "Speed", min: 0, max: 2, step: 0.01 },
    { key: "amplitude", label: "Amplitude", min: 0, max: 8, step: 0.05 },
    { key: "waveScale", label: "Wave scale", min: 0.05, max: 2, step: 0.01 },
    { key: "waveRatio", label: "Wave ratio", min: 0.1, max: 3, step: 0.01 },
    { key: "swell", label: "Swell", min: 0, max: 100, step: 0.5 },
    { key: "turbulence", label: "Turbulence", min: 0, max: 100, step: 0.5 },
    { key: "tilt", label: "Tilt (rad)", min: 0, max: 3.14, step: 0.01 },
    { key: "zoom", label: "Zoom", min: 0.1, max: 3, step: 0.01 },
    { key: "height", label: "Horizon height", min: -20, max: 20, step: 0.1 },
    { key: "fogDepth", label: "Fog depth", min: 1, max: 60, step: 0.5 },
    { key: "brightness", label: "Brightness", min: 0, max: 2, step: 0.01 },
    { key: "opacity", label: "Opacity", min: 0, max: 1, step: 0.01 },
    { key: "parallaxStrength", label: "Parallax", min: 0, max: 2, step: 0.01 },
    {
      key: "introZoomFrom",
      label: "Intro zoom from",
      min: 0.05,
      max: 1,
      step: 0.01,
    },
    {
      key: "introStiffness",
      label: "Intro stiffness",
      min: 10,
      max: 400,
      step: 5,
    },
    { key: "introDamping", label: "Intro damping", min: 1, max: 60, step: 0.5 },
    {
      key: "grainIntensity",
      label: "Grain intensity",
      min: 0,
      max: 0.3,
      step: 0.005,
    },
    { key: "maxDpr", label: "Max DPR", min: 0.5, max: 3, step: 0.1 },
  ];

  const COLORS = [
    { key: "horizonColor", label: "Horizon" },
    { key: "waveColor", label: "Waves" },
    { key: "crestColor", label: "Crests" },
  ];

  const TOGGLES = [
    { key: "intro", label: "Intro animation" },
    { key: "mouseInteraction", label: "Pointer parallax" },
    { key: "grain", label: "Shader grain" },
  ];

  // Browsers restore form-control values across reloads and would replay them
  // over WAVES_CONFIG, so every control here opts out of that restoration.
  function noRestore(input) {
    input.autocomplete = "off";
    return input;
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function buildPanel(waves, defaults) {
    const panel = el("aside", "waves-panel");
    panel.setAttribute("aria-label", "Gradient waves controls");

    const head = el("div", "waves-panel-head");
    head.appendChild(el("h2", null, "Gradient waves"));
    const close = el("button", "waves-panel-close", "\u00d7");
    close.type = "button";
    close.setAttribute("aria-label", "Close controls");
    close.addEventListener("click", function () {
      panel.remove();
    });
    head.appendChild(close);
    panel.appendChild(head);

    const body = el("div", "waves-panel-body");
    panel.appendChild(body);

    // Any hands-on tuning ends the entrance animation, so a running spring
    // never fights a value being dragged. Capture phase: fires before the
    // per-control handlers below.
    ["input", "change"].forEach(function (type) {
      panel.addEventListener(
        type,
        function () {
          waves.endIntro();
        },
        true,
      );
    });

    // key -> function(value) that writes a config value into its control.
    const sync = {};

    let idSeq = 0;
    function nextId() {
      idSeq += 1;
      return "waves-ctl-" + idSeq;
    }

    /* colors */
    const colorRow = el("div", "waves-colors");
    COLORS.forEach(function (def) {
      const id = nextId();
      const wrap = el("div", "waves-color");
      const label = el("label", null, def.label);
      label.htmlFor = id;
      const input = noRestore(document.createElement("input"));
      input.type = "color";
      input.id = id;
      input.addEventListener("input", function () {
        const patch = {};
        patch[def.key] = input.value;
        waves.apply(patch);
      });
      sync[def.key] = function (value) {
        input.value = toHex(parseColor(value));
      };
      wrap.appendChild(label);
      wrap.appendChild(input);
      colorRow.appendChild(wrap);
    });
    body.appendChild(colorRow);

    /* detail select */
    const detailId = nextId();
    const detailRow = el("div", "waves-row waves-row-select");
    const detailLabel = el("label", null, "Detail");
    detailLabel.htmlFor = detailId;
    const detailSelect = noRestore(document.createElement("select"));
    detailSelect.id = detailId;
    ["low", "medium", "high"].forEach(function (tier) {
      const option = document.createElement("option");
      option.value = tier;
      option.textContent = tier;
      detailSelect.appendChild(option);
    });
    detailSelect.addEventListener("change", function () {
      waves.apply({ detail: detailSelect.value });
    });
    sync.detail = function (value) {
      detailSelect.value = value;
    };
    detailRow.appendChild(detailLabel);
    detailRow.appendChild(detailSelect);
    body.appendChild(detailRow);

    /* toggles */
    TOGGLES.forEach(function (def) {
      const id = nextId();
      const row = el("div", "waves-row waves-row-toggle");
      const input = noRestore(document.createElement("input"));
      input.type = "checkbox";
      input.id = id;
      const label = el("label", null, def.label);
      label.htmlFor = id;
      input.addEventListener("change", function () {
        const patch = {};
        patch[def.key] = input.checked;
        waves.apply(patch);
      });
      sync[def.key] = function (value) {
        input.checked = Boolean(value);
      };
      row.appendChild(input);
      row.appendChild(label);
      body.appendChild(row);
    });

    /* sliders */
    SLIDERS.forEach(function (def) {
      const id = nextId();
      const row = el("div", "waves-row");
      const label = el("label", null, def.label);
      label.htmlFor = id;
      const output = el("output", "waves-value");
      output.htmlFor = id;
      const input = noRestore(document.createElement("input"));
      input.type = "range";
      input.id = id;
      input.min = String(def.min);
      input.max = String(def.max);
      input.step = String(def.step);
      input.addEventListener("input", function () {
        const next = parseFloat(input.value);
        output.textContent = String(next);
        const patch = {};
        patch[def.key] = next;
        waves.apply(patch);
      });
      sync[def.key] = function (value) {
        input.value = String(value);
        output.textContent = String(value);
      };
      const rowHead = el("div", "waves-row-head");
      rowHead.appendChild(label);
      rowHead.appendChild(output);
      row.appendChild(rowHead);
      row.appendChild(input);
      body.appendChild(row);
    });

    // Push a config object out to every control. Browsers replay their own
    // remembered control values when a page is reloaded from history, which
    // would otherwise leave the panel showing values the config never set —
    // so this runs again after load, once that replay has happened.
    function syncAll(source) {
      Object.keys(sync).forEach(function (key) {
        if (source[key] !== undefined) sync[key](source[key]);
      });
    }

    // On a fresh load the config in this file is the source of truth, so the
    // replayed values are re-overwritten in both directions: state and control.
    function reassert() {
      waves.apply(defaults);
      syncAll(defaults);
    }

    syncAll(waves.state);
    // pageshow fires after the browser has finished replaying remembered form
    // state (including on history and back/forward-cache loads), so this is
    // the point where re-asserting the config actually sticks.
    window.addEventListener("pageshow", function () {
      requestAnimationFrame(reassert);
    });

    /* actions */
    const actions = el("div", "waves-panel-actions");

    const copy = el("button", "waves-btn waves-btn-primary", "Copy config");
    copy.type = "button";
    copy.addEventListener("click", function () {
      const text = serializeConfig(waves.state);
      const done = function (ok) {
        copy.textContent = ok ? "Copied" : "Press \u2318C";
        setTimeout(function () {
          copy.textContent = "Copy config";
        }, 1800);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(
          function () {
            done(true);
          },
          function () {
            window.prompt("Copy this config:", text);
            done(false);
          },
        );
      } else {
        window.prompt("Copy this config:", text);
        done(false);
      }
    });
    actions.appendChild(copy);

    const replay = el("button", "waves-btn", "Replay intro");
    replay.type = "button";
    replay.addEventListener("click", function () {
      waves.replayIntro();
    });
    actions.appendChild(replay);

    const reset = el("button", "waves-btn", "Reset");
    reset.type = "button";
    reset.addEventListener("click", function () {
      waves.apply(defaults);
      syncAll(defaults);
      waves.replayIntro();
    });
    actions.appendChild(reset);

    panel.appendChild(actions);
    document.body.appendChild(panel);
  }

  // Emit a paste-ready block matching the WAVES_CONFIG shape above.
  function serializeConfig(state) {
    const order = [
      "horizonColor",
      "waveColor",
      "crestColor",
      "speed",
      "amplitude",
      "waveScale",
      "waveRatio",
      "swell",
      "turbulence",
      "tilt",
      "zoom",
      "height",
      "fogDepth",
      "detail",
      "brightness",
      "opacity",
      "intro",
      "introZoomFrom",
      "introStiffness",
      "introDamping",
      "mouseInteraction",
      "parallaxStrength",
      "grain",
      "grainIntensity",
      "maxDpr",
    ];
    const lines = order.map(function (key) {
      const value = state[key];
      const printed =
        typeof value === "string" ? "'" + value + "'" : String(value);
      return "  " + key + ": " + printed + ",";
    });
    return "const WAVES_CONFIG = {\n" + lines.join("\n") + "\n};";
  }

  /* ------------------------------------------------------------------------
     Boot
     ------------------------------------------------------------------------ */

  function init() {
    const container = document.querySelector(".hero-waves");
    if (!container) return;

    const waves = createWaves(container, WAVES_CONFIG);
    if (!waves) return; // no WebGL2 — CSS glow fallback stays visible

    document.documentElement.classList.add("waves-active");

    // The load curtain releases the zoom spring, so the background motion and
    // the hero copy arrive together. If the intro was never armed — reduced
    // motion, or a repeat visit already revealed — start immediately.
    if (document.documentElement.classList.contains("intro-armed")) {
      document.addEventListener("wispr:reveal", waves.releaseIntro, {
        once: true,
      });
    } else {
      waves.releaseIntro();
    }

    const tuning =
      /(^|[?&])tune=1(&|$)/.test(window.location.search) ||
      window.location.hash === "#tune";
    if (tuning) {
      buildPanel(waves, Object.assign({}, WAVES_CONFIG));
      // Handy for tweaking from the console: __waves.apply({ speed: 0.6 })
      window.__waves = waves;
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
