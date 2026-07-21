var __defProp = Object.defineProperty;
var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });
var __publicField = (obj, key, value) => {
  __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);
  return value;
};

// node_modules/unenv/dist/runtime/_internal/utils.mjs
function createNotImplementedError(name) {
  return new Error(`[unenv] ${name} is not implemented yet!`);
}
__name(createNotImplementedError, "createNotImplementedError");
function notImplemented(name) {
  const fn = /* @__PURE__ */ __name(() => {
    throw createNotImplementedError(name);
  }, "fn");
  return Object.assign(fn, { __unenv__: true });
}
__name(notImplemented, "notImplemented");
function notImplementedClass(name) {
  return class {
    __unenv__ = true;
    constructor() {
      throw new Error(`[unenv] ${name} is not implemented yet!`);
    }
  };
}
__name(notImplementedClass, "notImplementedClass");

// node_modules/unenv/dist/runtime/node/internal/perf_hooks/performance.mjs
var _timeOrigin = globalThis.performance?.timeOrigin ?? Date.now();
var _performanceNow = globalThis.performance?.now ? globalThis.performance.now.bind(globalThis.performance) : () => Date.now() - _timeOrigin;
var nodeTiming = {
  name: "node",
  entryType: "node",
  startTime: 0,
  duration: 0,
  nodeStart: 0,
  v8Start: 0,
  bootstrapComplete: 0,
  environment: 0,
  loopStart: 0,
  loopExit: 0,
  idleTime: 0,
  uvMetricsInfo: {
    loopCount: 0,
    events: 0,
    eventsWaiting: 0
  },
  detail: void 0,
  toJSON() {
    return this;
  }
};
var PerformanceEntry = class {
  __unenv__ = true;
  detail;
  entryType = "event";
  name;
  startTime;
  constructor(name, options) {
    this.name = name;
    this.startTime = options?.startTime || _performanceNow();
    this.detail = options?.detail;
  }
  get duration() {
    return _performanceNow() - this.startTime;
  }
  toJSON() {
    return {
      name: this.name,
      entryType: this.entryType,
      startTime: this.startTime,
      duration: this.duration,
      detail: this.detail
    };
  }
};
__name(PerformanceEntry, "PerformanceEntry");
var PerformanceMark = /* @__PURE__ */ __name(class PerformanceMark2 extends PerformanceEntry {
  entryType = "mark";
  constructor() {
    super(...arguments);
  }
  get duration() {
    return 0;
  }
}, "PerformanceMark");
var PerformanceMeasure = class extends PerformanceEntry {
  entryType = "measure";
};
__name(PerformanceMeasure, "PerformanceMeasure");
var PerformanceResourceTiming = class extends PerformanceEntry {
  entryType = "resource";
  serverTiming = [];
  connectEnd = 0;
  connectStart = 0;
  decodedBodySize = 0;
  domainLookupEnd = 0;
  domainLookupStart = 0;
  encodedBodySize = 0;
  fetchStart = 0;
  initiatorType = "";
  name = "";
  nextHopProtocol = "";
  redirectEnd = 0;
  redirectStart = 0;
  requestStart = 0;
  responseEnd = 0;
  responseStart = 0;
  secureConnectionStart = 0;
  startTime = 0;
  transferSize = 0;
  workerStart = 0;
  responseStatus = 0;
};
__name(PerformanceResourceTiming, "PerformanceResourceTiming");
var PerformanceObserverEntryList = class {
  __unenv__ = true;
  getEntries() {
    return [];
  }
  getEntriesByName(_name, _type) {
    return [];
  }
  getEntriesByType(type) {
    return [];
  }
};
__name(PerformanceObserverEntryList, "PerformanceObserverEntryList");
var Performance = class {
  __unenv__ = true;
  timeOrigin = _timeOrigin;
  eventCounts = /* @__PURE__ */ new Map();
  _entries = [];
  _resourceTimingBufferSize = 0;
  navigation = void 0;
  timing = void 0;
  timerify(_fn, _options) {
    throw createNotImplementedError("Performance.timerify");
  }
  get nodeTiming() {
    return nodeTiming;
  }
  eventLoopUtilization() {
    return {};
  }
  markResourceTiming() {
    return new PerformanceResourceTiming("");
  }
  onresourcetimingbufferfull = null;
  now() {
    if (this.timeOrigin === _timeOrigin) {
      return _performanceNow();
    }
    return Date.now() - this.timeOrigin;
  }
  clearMarks(markName) {
    this._entries = markName ? this._entries.filter((e) => e.name !== markName) : this._entries.filter((e) => e.entryType !== "mark");
  }
  clearMeasures(measureName) {
    this._entries = measureName ? this._entries.filter((e) => e.name !== measureName) : this._entries.filter((e) => e.entryType !== "measure");
  }
  clearResourceTimings() {
    this._entries = this._entries.filter((e) => e.entryType !== "resource" || e.entryType !== "navigation");
  }
  getEntries() {
    return this._entries;
  }
  getEntriesByName(name, type) {
    return this._entries.filter((e) => e.name === name && (!type || e.entryType === type));
  }
  getEntriesByType(type) {
    return this._entries.filter((e) => e.entryType === type);
  }
  mark(name, options) {
    const entry = new PerformanceMark(name, options);
    this._entries.push(entry);
    return entry;
  }
  measure(measureName, startOrMeasureOptions, endMark) {
    let start;
    let end;
    if (typeof startOrMeasureOptions === "string") {
      start = this.getEntriesByName(startOrMeasureOptions, "mark")[0]?.startTime;
      end = this.getEntriesByName(endMark, "mark")[0]?.startTime;
    } else {
      start = Number.parseFloat(startOrMeasureOptions?.start) || this.now();
      end = Number.parseFloat(startOrMeasureOptions?.end) || this.now();
    }
    const entry = new PerformanceMeasure(measureName, {
      startTime: start,
      detail: {
        start,
        end
      }
    });
    this._entries.push(entry);
    return entry;
  }
  setResourceTimingBufferSize(maxSize) {
    this._resourceTimingBufferSize = maxSize;
  }
  addEventListener(type, listener, options) {
    throw createNotImplementedError("Performance.addEventListener");
  }
  removeEventListener(type, listener, options) {
    throw createNotImplementedError("Performance.removeEventListener");
  }
  dispatchEvent(event) {
    throw createNotImplementedError("Performance.dispatchEvent");
  }
  toJSON() {
    return this;
  }
};
__name(Performance, "Performance");
var PerformanceObserver = class {
  __unenv__ = true;
  _callback = null;
  constructor(callback) {
    this._callback = callback;
  }
  takeRecords() {
    return [];
  }
  disconnect() {
    throw createNotImplementedError("PerformanceObserver.disconnect");
  }
  observe(options) {
    throw createNotImplementedError("PerformanceObserver.observe");
  }
  bind(fn) {
    return fn;
  }
  runInAsyncScope(fn, thisArg, ...args) {
    return fn.call(thisArg, ...args);
  }
  asyncId() {
    return 0;
  }
  triggerAsyncId() {
    return 0;
  }
  emitDestroy() {
    return this;
  }
};
__name(PerformanceObserver, "PerformanceObserver");
__publicField(PerformanceObserver, "supportedEntryTypes", []);
var performance = globalThis.performance && "addEventListener" in globalThis.performance ? globalThis.performance : new Performance();

// node_modules/@cloudflare/unenv-preset/dist/runtime/polyfill/performance.mjs
globalThis.performance = performance;
globalThis.Performance = Performance;
globalThis.PerformanceEntry = PerformanceEntry;
globalThis.PerformanceMark = PerformanceMark;
globalThis.PerformanceMeasure = PerformanceMeasure;
globalThis.PerformanceObserver = PerformanceObserver;
globalThis.PerformanceObserverEntryList = PerformanceObserverEntryList;
globalThis.PerformanceResourceTiming = PerformanceResourceTiming;

// node_modules/unenv/dist/runtime/node/console.mjs
import { Writable } from "node:stream";

// node_modules/unenv/dist/runtime/mock/noop.mjs
var noop_default = Object.assign(() => {
}, { __unenv__: true });

// node_modules/unenv/dist/runtime/node/console.mjs
var _console = globalThis.console;
var _ignoreErrors = true;
var _stderr = new Writable();
var _stdout = new Writable();
var log = _console?.log ?? noop_default;
var info = _console?.info ?? log;
var trace = _console?.trace ?? info;
var debug = _console?.debug ?? log;
var table = _console?.table ?? log;
var error = _console?.error ?? log;
var warn = _console?.warn ?? error;
var createTask = _console?.createTask ?? /* @__PURE__ */ notImplemented("console.createTask");
var clear = _console?.clear ?? noop_default;
var count = _console?.count ?? noop_default;
var countReset = _console?.countReset ?? noop_default;
var dir = _console?.dir ?? noop_default;
var dirxml = _console?.dirxml ?? noop_default;
var group = _console?.group ?? noop_default;
var groupEnd = _console?.groupEnd ?? noop_default;
var groupCollapsed = _console?.groupCollapsed ?? noop_default;
var profile = _console?.profile ?? noop_default;
var profileEnd = _console?.profileEnd ?? noop_default;
var time = _console?.time ?? noop_default;
var timeEnd = _console?.timeEnd ?? noop_default;
var timeLog = _console?.timeLog ?? noop_default;
var timeStamp = _console?.timeStamp ?? noop_default;
var Console = _console?.Console ?? /* @__PURE__ */ notImplementedClass("console.Console");
var _times = /* @__PURE__ */ new Map();
var _stdoutErrorHandler = noop_default;
var _stderrErrorHandler = noop_default;

// node_modules/@cloudflare/unenv-preset/dist/runtime/node/console.mjs
var workerdConsole = globalThis["console"];
var {
  assert,
  clear: clear2,
  // @ts-expect-error undocumented public API
  context,
  count: count2,
  countReset: countReset2,
  // @ts-expect-error undocumented public API
  createTask: createTask2,
  debug: debug2,
  dir: dir2,
  dirxml: dirxml2,
  error: error2,
  group: group2,
  groupCollapsed: groupCollapsed2,
  groupEnd: groupEnd2,
  info: info2,
  log: log2,
  profile: profile2,
  profileEnd: profileEnd2,
  table: table2,
  time: time2,
  timeEnd: timeEnd2,
  timeLog: timeLog2,
  timeStamp: timeStamp2,
  trace: trace2,
  warn: warn2
} = workerdConsole;
Object.assign(workerdConsole, {
  Console,
  _ignoreErrors,
  _stderr,
  _stderrErrorHandler,
  _stdout,
  _stdoutErrorHandler,
  _times
});
var console_default = workerdConsole;

// node_modules/wrangler/_virtual_unenv_global_polyfill-@cloudflare-unenv-preset-node-console
globalThis.console = console_default;

// node_modules/unenv/dist/runtime/node/internal/process/hrtime.mjs
var hrtime = /* @__PURE__ */ Object.assign(/* @__PURE__ */ __name(function hrtime2(startTime) {
  const now = Date.now();
  const seconds = Math.trunc(now / 1e3);
  const nanos = now % 1e3 * 1e6;
  if (startTime) {
    let diffSeconds = seconds - startTime[0];
    let diffNanos = nanos - startTime[0];
    if (diffNanos < 0) {
      diffSeconds = diffSeconds - 1;
      diffNanos = 1e9 + diffNanos;
    }
    return [diffSeconds, diffNanos];
  }
  return [seconds, nanos];
}, "hrtime"), { bigint: /* @__PURE__ */ __name(function bigint() {
  return BigInt(Date.now() * 1e6);
}, "bigint") });

// node_modules/unenv/dist/runtime/node/internal/process/process.mjs
import { EventEmitter } from "node:events";

// node_modules/unenv/dist/runtime/node/internal/tty/read-stream.mjs
import { Socket } from "node:net";
var ReadStream = class extends Socket {
  fd;
  constructor(fd) {
    super();
    this.fd = fd;
  }
  isRaw = false;
  setRawMode(mode) {
    this.isRaw = mode;
    return this;
  }
  isTTY = false;
};
__name(ReadStream, "ReadStream");

// node_modules/unenv/dist/runtime/node/internal/tty/write-stream.mjs
import { Socket as Socket2 } from "node:net";
var WriteStream = class extends Socket2 {
  fd;
  constructor(fd) {
    super();
    this.fd = fd;
  }
  clearLine(dir3, callback) {
    callback && callback();
    return false;
  }
  clearScreenDown(callback) {
    callback && callback();
    return false;
  }
  cursorTo(x, y, callback) {
    callback && typeof callback === "function" && callback();
    return false;
  }
  moveCursor(dx, dy, callback) {
    callback && callback();
    return false;
  }
  getColorDepth(env2) {
    return 1;
  }
  hasColors(count3, env2) {
    return false;
  }
  getWindowSize() {
    return [this.columns, this.rows];
  }
  columns = 80;
  rows = 24;
  isTTY = false;
};
__name(WriteStream, "WriteStream");

// node_modules/unenv/dist/runtime/node/internal/process/process.mjs
var Process = class extends EventEmitter {
  env;
  hrtime;
  nextTick;
  constructor(impl) {
    super();
    this.env = impl.env;
    this.hrtime = impl.hrtime;
    this.nextTick = impl.nextTick;
    for (const prop of [...Object.getOwnPropertyNames(Process.prototype), ...Object.getOwnPropertyNames(EventEmitter.prototype)]) {
      const value = this[prop];
      if (typeof value === "function") {
        this[prop] = value.bind(this);
      }
    }
  }
  emitWarning(warning, type, code) {
    console.warn(`${code ? `[${code}] ` : ""}${type ? `${type}: ` : ""}${warning}`);
  }
  emit(...args) {
    return super.emit(...args);
  }
  listeners(eventName) {
    return super.listeners(eventName);
  }
  #stdin;
  #stdout;
  #stderr;
  get stdin() {
    return this.#stdin ??= new ReadStream(0);
  }
  get stdout() {
    return this.#stdout ??= new WriteStream(1);
  }
  get stderr() {
    return this.#stderr ??= new WriteStream(2);
  }
  #cwd = "/";
  chdir(cwd2) {
    this.#cwd = cwd2;
  }
  cwd() {
    return this.#cwd;
  }
  arch = "";
  platform = "";
  argv = [];
  argv0 = "";
  execArgv = [];
  execPath = "";
  title = "";
  pid = 200;
  ppid = 100;
  get version() {
    return "";
  }
  get versions() {
    return {};
  }
  get allowedNodeEnvironmentFlags() {
    return /* @__PURE__ */ new Set();
  }
  get sourceMapsEnabled() {
    return false;
  }
  get debugPort() {
    return 0;
  }
  get throwDeprecation() {
    return false;
  }
  get traceDeprecation() {
    return false;
  }
  get features() {
    return {};
  }
  get release() {
    return {};
  }
  get connected() {
    return false;
  }
  get config() {
    return {};
  }
  get moduleLoadList() {
    return [];
  }
  constrainedMemory() {
    return 0;
  }
  availableMemory() {
    return 0;
  }
  uptime() {
    return 0;
  }
  resourceUsage() {
    return {};
  }
  ref() {
  }
  unref() {
  }
  umask() {
    throw createNotImplementedError("process.umask");
  }
  getBuiltinModule() {
    return void 0;
  }
  getActiveResourcesInfo() {
    throw createNotImplementedError("process.getActiveResourcesInfo");
  }
  exit() {
    throw createNotImplementedError("process.exit");
  }
  reallyExit() {
    throw createNotImplementedError("process.reallyExit");
  }
  kill() {
    throw createNotImplementedError("process.kill");
  }
  abort() {
    throw createNotImplementedError("process.abort");
  }
  dlopen() {
    throw createNotImplementedError("process.dlopen");
  }
  setSourceMapsEnabled() {
    throw createNotImplementedError("process.setSourceMapsEnabled");
  }
  loadEnvFile() {
    throw createNotImplementedError("process.loadEnvFile");
  }
  disconnect() {
    throw createNotImplementedError("process.disconnect");
  }
  cpuUsage() {
    throw createNotImplementedError("process.cpuUsage");
  }
  setUncaughtExceptionCaptureCallback() {
    throw createNotImplementedError("process.setUncaughtExceptionCaptureCallback");
  }
  hasUncaughtExceptionCaptureCallback() {
    throw createNotImplementedError("process.hasUncaughtExceptionCaptureCallback");
  }
  initgroups() {
    throw createNotImplementedError("process.initgroups");
  }
  openStdin() {
    throw createNotImplementedError("process.openStdin");
  }
  assert() {
    throw createNotImplementedError("process.assert");
  }
  binding() {
    throw createNotImplementedError("process.binding");
  }
  permission = { has: /* @__PURE__ */ notImplemented("process.permission.has") };
  report = {
    directory: "",
    filename: "",
    signal: "SIGUSR2",
    compact: false,
    reportOnFatalError: false,
    reportOnSignal: false,
    reportOnUncaughtException: false,
    getReport: /* @__PURE__ */ notImplemented("process.report.getReport"),
    writeReport: /* @__PURE__ */ notImplemented("process.report.writeReport")
  };
  finalization = {
    register: /* @__PURE__ */ notImplemented("process.finalization.register"),
    unregister: /* @__PURE__ */ notImplemented("process.finalization.unregister"),
    registerBeforeExit: /* @__PURE__ */ notImplemented("process.finalization.registerBeforeExit")
  };
  memoryUsage = Object.assign(() => ({
    arrayBuffers: 0,
    rss: 0,
    external: 0,
    heapTotal: 0,
    heapUsed: 0
  }), { rss: () => 0 });
  mainModule = void 0;
  domain = void 0;
  send = void 0;
  exitCode = void 0;
  channel = void 0;
  getegid = void 0;
  geteuid = void 0;
  getgid = void 0;
  getgroups = void 0;
  getuid = void 0;
  setegid = void 0;
  seteuid = void 0;
  setgid = void 0;
  setgroups = void 0;
  setuid = void 0;
  _events = void 0;
  _eventsCount = void 0;
  _exiting = void 0;
  _maxListeners = void 0;
  _debugEnd = void 0;
  _debugProcess = void 0;
  _fatalException = void 0;
  _getActiveHandles = void 0;
  _getActiveRequests = void 0;
  _kill = void 0;
  _preload_modules = void 0;
  _rawDebug = void 0;
  _startProfilerIdleNotifier = void 0;
  _stopProfilerIdleNotifier = void 0;
  _tickCallback = void 0;
  _disconnect = void 0;
  _handleQueue = void 0;
  _pendingMessage = void 0;
  _channel = void 0;
  _send = void 0;
  _linkedBinding = void 0;
};
__name(Process, "Process");

// node_modules/@cloudflare/unenv-preset/dist/runtime/node/process.mjs
var globalProcess = globalThis["process"];
var getBuiltinModule = globalProcess.getBuiltinModule;
var { exit, platform, nextTick } = getBuiltinModule(
  "node:process"
);
var unenvProcess = new Process({
  env: globalProcess.env,
  hrtime,
  nextTick
});
var {
  abort,
  addListener,
  allowedNodeEnvironmentFlags,
  hasUncaughtExceptionCaptureCallback,
  setUncaughtExceptionCaptureCallback,
  loadEnvFile,
  sourceMapsEnabled,
  arch,
  argv,
  argv0,
  chdir,
  config,
  connected,
  constrainedMemory,
  availableMemory,
  cpuUsage,
  cwd,
  debugPort,
  dlopen,
  disconnect,
  emit,
  emitWarning,
  env,
  eventNames,
  execArgv,
  execPath,
  finalization,
  features,
  getActiveResourcesInfo,
  getMaxListeners,
  hrtime: hrtime3,
  kill,
  listeners,
  listenerCount,
  memoryUsage,
  on,
  off,
  once,
  pid,
  ppid,
  prependListener,
  prependOnceListener,
  rawListeners,
  release,
  removeAllListeners,
  removeListener,
  report,
  resourceUsage,
  setMaxListeners,
  setSourceMapsEnabled,
  stderr,
  stdin,
  stdout,
  title,
  throwDeprecation,
  traceDeprecation,
  umask,
  uptime,
  version,
  versions,
  domain,
  initgroups,
  moduleLoadList,
  reallyExit,
  openStdin,
  assert: assert2,
  binding,
  send,
  exitCode,
  channel,
  getegid,
  geteuid,
  getgid,
  getgroups,
  getuid,
  setegid,
  seteuid,
  setgid,
  setgroups,
  setuid,
  permission,
  mainModule,
  _events,
  _eventsCount,
  _exiting,
  _maxListeners,
  _debugEnd,
  _debugProcess,
  _fatalException,
  _getActiveHandles,
  _getActiveRequests,
  _kill,
  _preload_modules,
  _rawDebug,
  _startProfilerIdleNotifier,
  _stopProfilerIdleNotifier,
  _tickCallback,
  _disconnect,
  _handleQueue,
  _pendingMessage,
  _channel,
  _send,
  _linkedBinding
} = unenvProcess;
var _process = {
  abort,
  addListener,
  allowedNodeEnvironmentFlags,
  hasUncaughtExceptionCaptureCallback,
  setUncaughtExceptionCaptureCallback,
  loadEnvFile,
  sourceMapsEnabled,
  arch,
  argv,
  argv0,
  chdir,
  config,
  connected,
  constrainedMemory,
  availableMemory,
  cpuUsage,
  cwd,
  debugPort,
  dlopen,
  disconnect,
  emit,
  emitWarning,
  env,
  eventNames,
  execArgv,
  execPath,
  exit,
  finalization,
  features,
  getBuiltinModule,
  getActiveResourcesInfo,
  getMaxListeners,
  hrtime: hrtime3,
  kill,
  listeners,
  listenerCount,
  memoryUsage,
  nextTick,
  on,
  off,
  once,
  pid,
  platform,
  ppid,
  prependListener,
  prependOnceListener,
  rawListeners,
  release,
  removeAllListeners,
  removeListener,
  report,
  resourceUsage,
  setMaxListeners,
  setSourceMapsEnabled,
  stderr,
  stdin,
  stdout,
  title,
  throwDeprecation,
  traceDeprecation,
  umask,
  uptime,
  version,
  versions,
  // @ts-expect-error old API
  domain,
  initgroups,
  moduleLoadList,
  reallyExit,
  openStdin,
  assert: assert2,
  binding,
  send,
  exitCode,
  channel,
  getegid,
  geteuid,
  getgid,
  getgroups,
  getuid,
  setegid,
  seteuid,
  setgid,
  setgroups,
  setuid,
  permission,
  mainModule,
  _events,
  _eventsCount,
  _exiting,
  _maxListeners,
  _debugEnd,
  _debugProcess,
  _fatalException,
  _getActiveHandles,
  _getActiveRequests,
  _kill,
  _preload_modules,
  _rawDebug,
  _startProfilerIdleNotifier,
  _stopProfilerIdleNotifier,
  _tickCallback,
  _disconnect,
  _handleQueue,
  _pendingMessage,
  _channel,
  _send,
  _linkedBinding
};
var process_default = _process;

// node_modules/wrangler/_virtual_unenv_global_polyfill-@cloudflare-unenv-preset-node-process
globalThis.process = process_default;

// src/worker.ts
import { WorkerEntrypoint } from "cloudflare:workers";

// node_modules/unenv/dist/runtime/node/internal/crypto/node.mjs
var webcrypto = new Proxy(globalThis.crypto, { get(_, key) {
  if (key === "CryptoKey") {
    return globalThis.CryptoKey;
  }
  if (typeof globalThis.crypto[key] === "function") {
    return globalThis.crypto[key].bind(globalThis.crypto);
  }
  return globalThis.crypto[key];
} });

// node_modules/@cloudflare/unenv-preset/dist/runtime/node/crypto.mjs
var workerdCrypto = process.getBuiltinModule("node:crypto");
var {
  Certificate,
  DiffieHellman,
  DiffieHellmanGroup,
  Hash,
  Hmac,
  KeyObject,
  X509Certificate,
  checkPrime,
  checkPrimeSync,
  createDiffieHellman,
  createDiffieHellmanGroup,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  createSecretKey,
  generateKey,
  generateKeyPair,
  generateKeyPairSync,
  generateKeySync,
  generatePrime,
  generatePrimeSync,
  getCiphers,
  getCurves,
  getDiffieHellman,
  getFips,
  getHashes,
  hkdf,
  hkdfSync,
  pbkdf2,
  pbkdf2Sync,
  randomBytes,
  randomFill,
  randomFillSync,
  randomInt,
  randomUUID,
  scrypt,
  scryptSync,
  secureHeapUsed,
  setEngine,
  setFips,
  subtle,
  timingSafeEqual
} = workerdCrypto;
var getRandomValues = workerdCrypto.getRandomValues.bind(
  workerdCrypto.webcrypto
);
var webcrypto2 = {
  // @ts-expect-error unenv has unknown type
  CryptoKey: webcrypto.CryptoKey,
  getRandomValues,
  randomUUID,
  subtle
};
var fips = workerdCrypto.fips;

// ../shared-ts/src/hclCore.ts
var CATEGORY_ORDER = ["iam", "network", "storage", "compute", "kubernetes", "integration", "monitoring", "misc"];
var RESOURCE_CATEGORY_RULES = [
  { category: "iam", prefixes: ["aws_iam_", "aws_kms_", "aws_secretsmanager", "aws_acm"] },
  {
    category: "network",
    prefixes: [
      "aws_vpc",
      "aws_subnet",
      "aws_internet_gateway",
      "aws_nat",
      "aws_route",
      "aws_security_group",
      "aws_eip",
      "aws_lb",
      "aws_alb",
      "aws_elb",
      "aws_api_gateway",
      "aws_apigateway",
      "aws_cloudfront"
    ]
  },
  { category: "storage", prefixes: ["aws_s3", "aws_db_", "aws_rds", "aws_dynamodb", "aws_efs", "aws_elasticache"] },
  {
    category: "compute",
    prefixes: ["aws_instance", "aws_launch_template", "aws_autoscaling", "aws_lambda", "aws_eks", "aws_ecs", "aws_batch"]
  },
  { category: "kubernetes", prefixes: ["helm_", "kubernetes_"] },
  { category: "integration", prefixes: ["aws_sqs", "aws_sns", "aws_kinesis", "aws_mq", "aws_cloudwatch_event"] },
  { category: "monitoring", prefixes: ["aws_cloudwatch_log", "aws_cloudwatch_metric"] }
];
function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
__name(escapeRegExp, "escapeRegExp");
function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}
__name(isPlainObject, "isPlainObject");
function isDictOrList(v) {
  return v !== null && typeof v === "object";
}
__name(isDictOrList, "isDictOrList");
function isEmptyValue(v) {
  return v === null || v === "" || Array.isArray(v) && v.length === 0 || isPlainObject(v) && Object.keys(v).length === 0;
}
__name(isEmptyValue, "isEmptyValue");
var HCLGenerator = class {
  ignoredTypes;
  externalNodesLookup = {};
  usedDataSources = {};
  internalDataSources = [];
  requiredProviderAliases = /* @__PURE__ */ new Set();
  targetRegion = null;
  datasourceStrategies;
  datasourceHandlers;
  regionResolver;
  nestedSyntax;
  // Meta-argumentos do Terraform em si (não são atributo de provider) -- SEMPRE
  // bloco `chave { }`, mesmo quando nestedSyntax="attribute". Com "block" isso já
  // saía certo por acidente (todo dict vira bloco); só passou a importar de
  // verdade com o Cloudflare (Framework).
  tfMetaBlockKeys = /* @__PURE__ */ new Set(["lifecycle"]);
  localResourceSignatures = /* @__PURE__ */ new Set();
  nodeMap = {};
  constructor(options = {}) {
    this.ignoredTypes = options.ignoredTypes ?? /* @__PURE__ */ new Set();
    this.datasourceStrategies = options.datasourceStrategies ?? {};
    this.datasourceHandlers = options.datasourceHandlers ?? {};
    this.regionResolver = options.regionResolver ?? null;
    this.nestedSyntax = options.nestedSyntax ?? "block";
  }
  resolveReferenceDatasource(valueStrInput) {
    if (Object.keys(this.externalNodesLookup).length === 0)
      return valueStrInput;
    let valueStr = valueStrInput;
    for (const node of Object.values(this.externalNodesLookup)) {
      const resourceType = node.type;
      const logicalName = node.logicalName;
      if (!resourceType || !logicalName)
        continue;
      const baseRef = `${resourceType}.${logicalName}`;
      if (!valueStr.includes(baseRef))
        continue;
      const strategy = this.datasourceStrategies[resourceType] ?? {};
      const attrMapping = strategy.attribute_mapping ?? {};
      const defaultTargetType = strategy.target_type ?? resourceType;
      const regexBase = "(?<!data\\.)" + escapeRegExp(baseRef);
      const pattern = new RegExp(regexBase + "\\.(\\w+)(?![\\w-])", "g");
      const replaced1 = valueStr.replace(pattern, (_match, requestedAttr) => {
        if (requestedAttr in attrMapping) {
          const rule = attrMapping[requestedAttr];
          const tgtType = rule.target_type ?? defaultTargetType;
          const suffix = rule.suffix ?? "";
          return `data.${tgtType}.${logicalName}${suffix}`;
        }
        return `data.${defaultTargetType}.${logicalName}.${requestedAttr}`;
      });
      if (replaced1 !== valueStr) {
        valueStr = replaced1;
        this.usedDataSources[`${resourceType}.${logicalName}`] = node;
      }
      const patternObject = new RegExp(regexBase + "(?![.\\w-])", "g");
      const replaced2 = valueStr.replace(patternObject, `data.${defaultTargetType}.${logicalName}`);
      if (replaced2 !== valueStr) {
        valueStr = replaced2;
        this.usedDataSources[`${resourceType}.${logicalName}`] = node;
      }
    }
    for (const [logName, resType] of this.internalDataSources) {
      const refStr = `${resType}.${logName}`;
      const pat = new RegExp("(?<!data\\.)" + escapeRegExp(refStr) + "(?![\\w-])", "g");
      const replaced = valueStr.replace(pat, `data.${resType}.${logName}`);
      if (replaced !== valueStr)
        valueStr = replaced;
    }
    return valueStr;
  }
  ensureParamLimit(textInput, maxLength = 100, hashLen = 8) {
    if (textInput.length <= maxLength)
      return textInput;
    const hashSuffix = createHash("md5").update(textInput).digest("hex").slice(0, hashLen);
    return textInput.slice(0, maxLength - hashLen) + hashSuffix;
  }
  addEmbeddedDataSource(node, dsDefinition) {
    if (!node._embedded_data_sources)
      node._embedded_data_sources = [];
    node._embedded_data_sources.push(dsDefinition);
  }
  getParamWeight([key, value]) {
    if (["count", "for_each", "source", "providers", "version"].includes(key))
      return [0, key];
    if (key === "name" || key === "id" || key.endsWith("_name") || key.endsWith("_id"))
      return [20, key];
    const keyLower = key.toLowerCase();
    if (keyLower === "sid")
      return [22, key];
    if (keyLower === "effect")
      return [23, key];
    if (["principal", "principals", "notprincipal"].includes(keyLower))
      return [24, key];
    if (["action", "actions", "notaction"].includes(keyLower))
      return [25, key];
    if (["resource", "resources", "notresource"].includes(keyLower))
      return [26, key];
    if (keyLower === "condition")
      return [27, key];
    if (isDictOrList(value)) {
      const isSimpleList = Array.isArray(value) && value.length > 0 && !isDictOrList(value[0]);
      if (!isSimpleList)
        return [90, key];
    }
    if (key === "lifecycle" || key === "depends_on")
      return [100, key];
    return [50, key];
  }
  formatHclValue(value, indentLevel = 2) {
    const currIndent = "  ".repeat(indentLevel);
    const prevIndent = "  ".repeat(indentLevel - 1);
    if (typeof value === "string") {
      let strValue = value;
      let valStripped = strValue.trim();
      if (Object.keys(this.externalNodesLookup).length > 0) {
        strValue = this.resolveReferenceDatasource(strValue);
        valStripped = strValue.trim();
      }
      if (strValue.startsWith("__RAW__"))
        return strValue.slice(7);
      if (valStripped.startsWith("<<"))
        return strValue;
      const expressionPrefixes = [
        "aws.",
        "var.",
        "local.",
        "module.",
        "data.",
        "self.",
        "count.index",
        "each.key",
        "each.value",
        "jsonencode(",
        "jsondecode(",
        "base64encode(",
        "base64decode(",
        "yamlencode(",
        "file(",
        "templatefile(",
        "sha1(",
        "sha256(",
        "md5(",
        "uuid(",
        "format(",
        "join(",
        "lookup(",
        "merge(",
        "flatten(",
        "replace(",
        "filemd5(",
        "tobool(",
        "tolist(",
        "tomap(",
        "tonumber(",
        "toset(",
        "tostring(",
        "concat(",
        "[for "
      ];
      if (expressionPrefixes.some((prefix) => valStripped.startsWith(prefix)))
        return strValue;
      const resourcePrefixes = ["aws_", "cloudflare_", "kubernetes_", "helm_", "time_", "random_"];
      if (resourcePrefixes.some((prefix) => valStripped.startsWith(prefix))) {
        if (valStripped.includes(".") || valStripped.includes("["))
          return strValue;
      }
      if (valStripped === "null")
        return "null";
      if (valStripped.toLowerCase() === "true")
        return "true";
      if (valStripped.toLowerCase() === "false")
        return "false";
      if (valStripped.includes("${")) {
        if (valStripped.startsWith('"') && valStripped.endsWith('"'))
          return strValue;
        return `"${strValue}"`;
      }
      if (strValue.includes("\n"))
        return `<<EOF
${strValue}
${prevIndent}EOF`;
      const escapedValue = strValue.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
      return `"${escapedValue}"`;
    }
    if (typeof value === "boolean")
      return value ? "true" : "false";
    if (typeof value === "number")
      return String(value);
    if (Array.isArray(value)) {
      const formattedItems = value.map((v) => this.formatHclValue(v, indentLevel + 1));
      if (formattedItems.some((item) => item.includes("\n"))) {
        const joinedItems = formattedItems.join(`,
${currIndent}`);
        return `[
${currIndent}${joinedItems}
${prevIndent}]`;
      }
      return `[${formattedItems.join(", ")}]`;
    }
    if (isPlainObject(value)) {
      const entries = Object.entries(value);
      if (entries.length === 0)
        return "{}";
      if (entries.length === 1 && entries[0][0] === "__yamlencode__") {
        return `yamlencode(${this.formatHclValue(entries[0][1], indentLevel + 1)})`;
      }
      if (entries.length === 1 && entries[0][0] === "__jsonencode__") {
        return `jsonencode(${this.formatHclValue(entries[0][1], indentLevel + 1)})`;
      }
      const lines = [];
      for (const [key, val] of entries) {
        const safeKey = /^[a-zA-Z0-9_-]+$/.test(key) ? key : `"${key}"`;
        lines.push(`${currIndent}${safeKey} = ${this.formatHclValue(val, indentLevel + 1)}`);
      }
      return `{
${lines.join("\n")}
${prevIndent}}`;
    }
    if (value === null)
      return "None";
    return String(value);
  }
  getDefinitionOrder(resourceType) {
    for (const rule of RESOURCE_CATEGORY_RULES) {
      for (let i = 0; i < rule.prefixes.length; i++) {
        if (resourceType.startsWith(rule.prefixes[i]))
          return i;
      }
    }
    return 999;
  }
  determineCategory(resourceType) {
    for (const rule of RESOURCE_CATEGORY_RULES) {
      if (rule.prefixes.some((p) => resourceType.startsWith(p)))
        return rule.category;
    }
    return "misc";
  }
  dispatchDatasource(resourceType, params, node, implicitList = []) {
    const handler = this.datasourceHandlers[resourceType];
    if (typeof handler === "function") {
      return handler(params, node, implicitList, this.usedDataSources, this.nodeMap);
    }
    return params;
  }
  generateExternalDataSources() {
    const blocks = [];
    if (Object.keys(this.usedDataSources).length === 0)
      return blocks;
    const processedKeys = /* @__PURE__ */ new Set();
    const renderedSignatures = /* @__PURE__ */ new Set();
    while (true) {
      const currentKeys = Object.keys(this.usedDataSources).filter((k) => !processedKeys.has(k));
      if (currentKeys.length === 0)
        break;
      for (const uniqueKey of currentKeys) {
        processedKeys.add(uniqueKey);
        const node = this.usedDataSources[uniqueKey];
        const resType = node.type;
        const logicalName = node.logicalName;
        if (!resType || resType.startsWith("cldmn_"))
          continue;
        const originalParams = node.cloudResource?.params ?? {};
        let dataParams = {};
        const strategy = this.datasourceStrategies[resType] ?? {};
        const stratType = strategy.type ?? "direct";
        const finalDsType = strategy.target_type ?? resType;
        let dsRegion = null;
        if (this.regionResolver) {
          const [, region] = this.regionResolver(node, this.nodeMap);
          dsRegion = region;
        }
        if (!dsRegion && resType === "aws_acm_certificate")
          dsRegion = "us-east-1";
        if (dsRegion && this.targetRegion && dsRegion !== this.targetRegion) {
          this.requiredProviderAliases.add(dsRegion);
          const aliasName = `aws.${dsRegion.replace(/-/g, "_")}`;
          dataParams.provider = aliasName;
        }
        if (stratType === "direct") {
          const targetAttr = strategy.attr ?? "name";
          const sourceParam = strategy.source_param ?? "name";
          const val = originalParams[sourceParam] || logicalName;
          dataParams[targetAttr] = val ?? null;
        } else if (stratType === "filter") {
          const tagKey = strategy.tag_key ?? "Name";
          const filtersList = [{ name: `tag:${tagKey}`, values: [logicalName ?? ""] }];
          const extraFilters = strategy.extra_filters ?? [];
          if (extraFilters.length > 0)
            filtersList.push(...extraFilters);
          dataParams.filter = filtersList;
        }
        const implicitBlocksInfo = [];
        dataParams = this.dispatchDatasource(resType, dataParams, node, implicitBlocksInfo);
        for (const implicit of implicitBlocksInfo) {
          const sig = `${implicit.type}::${implicit.name}`;
          if (!renderedSignatures.has(sig) && "text" in implicit) {
            blocks.push(implicit.text);
            renderedSignatures.add(sig);
          }
        }
        const mainSig = `${finalDsType}::${logicalName}`;
        if (!renderedSignatures.has(mainSig)) {
          blocks.push(this.renderBlock("data", finalDsType, logicalName ?? "", dataParams));
          renderedSignatures.add(mainSig);
        }
      }
    }
    return blocks;
  }
  generateHclText(payload, defaultsMap, domainNodeKeys, nodeMap = null, isK8sIntegrated = false) {
    const nodes = payload.nodes ?? [];
    this.nodeMap = nodeMap && Object.keys(nodeMap).length > 0 ? nodeMap : Object.fromEntries(nodes.map((n) => [n.key, n]));
    const validKeysSet = new Set(domainNodeKeys);
    this.targetRegion = null;
    for (const n of nodes) {
      if (n.type === "aws_region_") {
        this.targetRegion = n.cloudResource?.params?.region_name ?? null;
        break;
      }
    }
    this.requiredProviderAliases = /* @__PURE__ */ new Set();
    this.localResourceSignatures = /* @__PURE__ */ new Set();
    this.externalNodesLookup = {};
    for (const node of nodes) {
      const rType = node.type;
      const lName = node.logicalName;
      if (validKeysSet.has(node.key)) {
        if (rType && lName)
          this.localResourceSignatures.add(`${rType}.${lName}`);
      } else {
        this.externalNodesLookup[node.key] = node;
      }
    }
    const CONTAINER_TYPE = "system_global_datasource_container";
    const containerNodes = nodes.filter((n) => n.type === CONTAINER_TYPE);
    this.internalDataSources = [];
    for (const cNode of containerNodes) {
      for (const entry of cNode.entries ?? []) {
        const dsName = entry.logicalName;
        const dsType = entry.XTYPE;
        if (dsName && dsType)
          this.internalDataSources.push([dsName, dsType]);
      }
    }
    const globalDataBlocks = [];
    const categorizedBlocks = Object.fromEntries(
      CATEGORY_ORDER.map((cat) => [cat, []])
    );
    const validKeys = new Set(domainNodeKeys);
    if (containerNodes.length > 0) {
      for (const cNode of containerNodes) {
        for (const entry of cNode.entries ?? []) {
          const dsType = entry.XTYPE;
          const dsName = entry.logicalName;
          const dsParams = entry.params ?? {};
          if (dsType && dsName) {
            const block = this.renderBlock("data", dsType, dsName, dsParams);
            if (block)
              globalDataBlocks.push(block.trim());
          }
        }
      }
    }
    for (const node of nodes) {
      const key = node.key;
      const resType = node.type;
      if (resType === CONTAINER_TYPE)
        continue;
      if (!validKeys.has(key))
        continue;
      if (!resType)
        continue;
      if (resType.startsWith("cldmn_"))
        continue;
      if (resType.startsWith("kubernetes_")) {
        if (!isK8sIntegrated)
          continue;
        const allowedK8sTypes = ["kubernetes_secret_v1", "kubernetes_namespace", "kubernetes_manifest"];
        if (!allowedK8sTypes.includes(resType))
          continue;
      }
      if (node.pushCode === false)
        continue;
      const nodeBlocksBuffer = [];
      const legacyDataDef = node._temp_data_source_definition;
      if (legacyDataDef && Object.keys(legacyDataDef).length > 0) {
        nodeBlocksBuffer.push(this.renderBlock("data", legacyDataDef.XTYPE, legacyDataDef.logicalName, legacyDataDef));
      }
      for (const dsDef of node._embedded_data_sources ?? []) {
        const dsType = dsDef.XTYPE;
        const dsName = dsDef.logicalName;
        if (dsType && dsName)
          nodeBlocksBuffer.push(this.renderBlock("data", dsType, dsName, dsDef));
      }
      const embeddedLocals = node._embedded_locals;
      if (embeddedLocals && Object.keys(embeddedLocals).length > 0) {
        const localLines = ["locals {"];
        for (const [varName, varValue] of Object.entries(embeddedLocals)) {
          localLines.push(`  ${varName} = ${this.formatHclValue(varValue)}`);
        }
        localLines.push("}");
        nodeBlocksBuffer.push(localLines.join("\n"));
      }
      const logName = node.logicalName;
      if (logName && !this.ignoredTypes.has(resType)) {
        const cloudRes = node.cloudResource ?? {};
        const params = cloudRes.params ?? {};
        const provs = cloudRes.provisioners ?? [];
        const defaults = defaultsMap[resType] ?? {};
        const cleanParams = Object.fromEntries(Object.entries(params).filter(([k, v]) => v !== (defaults[k] ?? null)));
        if (Object.keys(cleanParams).length > 0 || provs.length > 0) {
          nodeBlocksBuffer.push(this.renderBlock("resource", resType, logName, cleanParams, provs));
        }
      }
      if (nodeBlocksBuffer.length > 0) {
        const fullBlockText = nodeBlocksBuffer.join("\n\n");
        const category = this.determineCategory(resType);
        categorizedBlocks[category].push({ type: resType, name: logName || "z_unknown", text: fullBlockText });
      }
    }
    const finalHclSegments = [];
    const externalDataBlocks = this.generateExternalDataSources();
    if (this.requiredProviderAliases.size > 0) {
      finalHclSegments.push("### ALTERNATE REGION PROVIDERS ###");
      for (const rAlias of [...this.requiredProviderAliases].sort()) {
        if (rAlias === this.targetRegion)
          continue;
        const aliasName = rAlias.replace(/-/g, "_");
        finalHclSegments.push(`provider "aws" {
  alias  = "${aliasName}"
  region = "${rAlias}"
}`);
      }
      finalHclSegments.push("\n");
    }
    if (globalDataBlocks.length > 0) {
      finalHclSegments.push("### SYSTEM DATA SOURCES ###");
      finalHclSegments.push(...globalDataBlocks);
      finalHclSegments.push("\n");
    }
    if (externalDataBlocks.length > 0) {
      finalHclSegments.push("### EXTERNAL REFERENCES ###");
      finalHclSegments.push(...externalDataBlocks);
      finalHclSegments.push("\n");
    }
    for (const category of CATEGORY_ORDER) {
      const blocksList = categorizedBlocks[category];
      if (blocksList.length === 0)
        continue;
      finalHclSegments.push(`### CATEGORY: ${category.toUpperCase()} ###`);
      blocksList.sort((a, b) => {
        const orderA = this.getDefinitionOrder(a.type);
        const orderB = this.getDefinitionOrder(b.type);
        if (orderA !== orderB)
          return orderA - orderB;
        if (a.type !== b.type)
          return a.type < b.type ? -1 : 1;
        return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
      });
      for (const item of blocksList)
        finalHclSegments.push(item.text);
      finalHclSegments.push("\n");
    }
    return finalHclSegments.filter(Boolean).join("\n\n");
  }
  renderParamsRecursive(paramsDict, indent, resourceType) {
    if (!isPlainObject(paramsDict))
      return [];
    const lines = [];
    const justification = 35 - indent.length;
    const rawItems = Object.entries(paramsDict);
    const sortedParams = [...rawItems].sort((itemA, itemB) => {
      const [wA, kA] = this.getParamWeight(itemA);
      const [wB, kB] = this.getParamWeight(itemB);
      if (wA !== wB)
        return wA - wB;
      return kA < kB ? -1 : kA > kB ? 1 : 0;
    });
    const simpleMapKeys = ["tags", "default_tags", "variables", "triggers", "data", "labels", "annotations", "values", "manifest"];
    for (const [key, value] of sortedParams) {
      if (key.endsWith("_") && !key.startsWith("__"))
        continue;
      if (isEmptyValue(value))
        continue;
      if (key === "condition" && resourceType === "aws_iam_policy_document" && isPlainObject(value)) {
        for (const [testName, testRules] of Object.entries(value)) {
          if (isPlainObject(testRules)) {
            for (const [varName, varVal] of Object.entries(testRules)) {
              lines.push(`${indent}condition {`);
              lines.push(`${indent}  test     = "${testName}"`);
              lines.push(`${indent}  variable = "${varName}"`);
              const valList = Array.isArray(varVal) ? varVal : [varVal];
              lines.push(`${indent}  values   = ${this.formatHclValue(valList)}`);
              lines.push(`${indent}}`);
            }
          }
        }
        continue;
      }
      let isRawExpression = false;
      if (key === "for_each") {
        isRawExpression = true;
      } else if (key === "ignore_changes") {
        if (Array.isArray(value)) {
          lines.push(`${indent}${key.padEnd(justification)} = [${value.map((v) => String(v)).join(", ")}]`);
        } else {
          lines.push(`${indent}${key.padEnd(justification)} = ${value}`);
        }
        continue;
      } else if (typeof value === "string") {
        const vClean = value.trim();
        if (vClean.startsWith("{for") || vClean.startsWith("[for"))
          isRawExpression = true;
      }
      if (isRawExpression) {
        lines.push(`${indent}${key.padEnd(justification)} = ${value}`);
        continue;
      }
      if (simpleMapKeys.includes(key)) {
        lines.push(`${indent}${key.padEnd(justification)} = ${this.formatHclValue(value)}`);
        continue;
      }
      const forceBlock = this.tfMetaBlockKeys.has(key);
      if (Array.isArray(value) && value.length > 0 && isPlainObject(value[0])) {
        if (this.nestedSyntax === "attribute" && !forceBlock) {
          lines.push(`${indent}${key.padEnd(justification)} = ${this.formatHclNested(value, indent)}`);
        } else {
          for (const item of value) {
            lines.push(`${indent}${key} {`);
            lines.push(...this.renderParamsRecursive(item, indent + "  ", resourceType));
            lines.push(`${indent}}`);
          }
        }
      } else if (isPlainObject(value)) {
        if (this.nestedSyntax === "attribute" && !forceBlock) {
          lines.push(`${indent}${key.padEnd(justification)} = ${this.formatHclNested(value, indent)}`);
        } else {
          lines.push(`${indent}${key} {`);
          lines.push(...this.renderParamsRecursive(value, indent + "  ", resourceType));
          lines.push(`${indent}}`);
        }
      } else {
        lines.push(`${indent}${key.padEnd(justification)} = ${this.formatHclValue(value)}`);
      }
    }
    return lines;
  }
  // Formata dict / lista-de-dict como objeto HCL inline (sintaxe do Terraform
  // Plugin Framework, ex.: Cloudflare 5.x): dict -> `{ k = v ... }`, lista ->
  // `[ {..}, {..} ]`. Só usado quando nestedSyntax == "attribute". Diferente de
  // formatHclValue: aqui as chaves do dict são ORDENADAS (Python faz
  // sorted(value.items())); em formatHclValue a ordem é a de inserção.
  formatHclNested(value, baseIndent) {
    if (Array.isArray(value)) {
      if (value.length === 0)
        return "[]";
      const parts = value.map((item) => baseIndent + "  " + this.formatHclNested(item, baseIndent + "  "));
      return "[\n" + parts.join(",\n") + "\n" + baseIndent + "]";
    }
    if (isPlainObject(value)) {
      const inner = [];
      const sortedEntries = Object.entries(value).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
      for (const [k, v] of sortedEntries) {
        if (isEmptyValue(v))
          continue;
        if (k.endsWith("_") && !k.startsWith("__"))
          continue;
        const rendered = isPlainObject(v) || Array.isArray(v) && v.length > 0 && isPlainObject(v[0]) ? this.formatHclNested(v, baseIndent + "  ") : this.formatHclValue(v);
        inner.push(`${baseIndent}  ${k} = ${rendered}`);
      }
      return "{\n" + inner.join("\n") + "\n" + baseIndent + "}";
    }
    return this.formatHclValue(value);
  }
  renderBlock(blockType, resourceType, name, params, provisioners = []) {
    const lines = [`${blockType} "${resourceType}" "${name}" {`];
    const filteredParams = Object.fromEntries(Object.entries(params).filter(([k]) => k !== "logicalName" && k !== "XTYPE"));
    lines.push(...this.renderParamsRecursive(filteredParams, "  ", resourceType));
    if (provisioners && provisioners.length > 0) {
      for (const prov of provisioners) {
        const pType = prov.type;
        if (!pType)
          continue;
        const pParams = Object.fromEntries(Object.entries(prov).filter(([k]) => k !== "type"));
        lines.push(`  provisioner "${pType}" {`);
        lines.push(...this.renderParamsRecursive(pParams, "    "));
        lines.push("  }");
      }
    }
    lines.push("}");
    return lines.join("\n");
  }
  applyStringReplacements(hclText) {
    hclText = hclText.replace(/aws_lb_Xalb\./g, "aws_lb.");
    hclText = hclText.replace(/"aws_lb_Xalb"/g, '"aws_lb"');
    hclText = this.resolveReferenceDatasource(hclText);
    return hclText;
  }
};
__name(HCLGenerator, "HCLGenerator");

// ../shared-ts/src/messageCollector.ts
var MessageCollector = class {
  errors = [];
  warnings = [];
  infos = [];
  errorsCross = [];
  warningsCross = [];
  infosCross = [];
  clear() {
    this.errors = [];
    this.warnings = [];
    this.infos = [];
    this.errorsCross = [];
    this.warningsCross = [];
    this.infosCross = [];
  }
  addError(msg, crossState = false) {
    this.errors.push(msg);
    this.errorsCross.push(crossState);
  }
  addWarning(msg, crossState = false) {
    this.warnings.push(msg);
    this.warningsCross.push(crossState);
  }
  addInfo(msg, crossState = false) {
    this.infos.push(msg);
    this.infosCross.push(crossState);
  }
  // Mantém a mensagem se: foi marcada crossState; OU não dá pra atribuir a um
  // nó (sem msg[1]) -- melhor mostrar do que engolir silenciosamente; OU o nó
  // pertence ao domínio deste state.
  filterDomain(msgs, crossFlags, domainKeys) {
    const out = [];
    msgs.forEach((msg, i) => {
      if (crossFlags[i]) {
        out.push(msg);
        return;
      }
      if (!Array.isArray(msg) || msg.length < 2) {
        out.push(msg);
        return;
      }
      if (domainKeys.has(msg[1]))
        out.push(msg);
    });
    return out;
  }
  // Sem argumento: devolve tudo (sem filtro) -- compatibilidade.
  // Com domainNodeKeys: aplica o filtro cross-state descrito acima.
  getAll(domainNodeKeys) {
    if (domainNodeKeys == null)
      return [this.errors, this.warnings, this.infos];
    const domainKeys = new Set(domainNodeKeys);
    return [
      this.filterDomain(this.errors, this.errorsCross, domainKeys),
      this.filterDomain(this.warnings, this.warningsCross, domainKeys),
      this.filterDomain(this.infos, this.infosCross, domainKeys)
    ];
  }
};
__name(MessageCollector, "MessageCollector");
var collector = new MessageCollector();

// src/ipv4.ts
function ipToInt(ip) {
  const p = ip.split(".").map((o) => parseInt(o, 10));
  return p[0] * 16777216 + p[1] * 65536 + p[2] * 256 + p[3];
}
__name(ipToInt, "ipToInt");
function intToIp(n) {
  return [Math.floor(n / 16777216) % 256, Math.floor(n / 65536) % 256, Math.floor(n / 256) % 256, n % 256].join(".");
}
__name(intToIp, "intToIp");
function parseNetwork(cidr) {
  const [ipStr, prefixStr] = cidr.split("/");
  const prefixLen = prefixStr !== void 0 ? parseInt(prefixStr, 10) : 32;
  const addrInt = ipToInt(ipStr);
  const hostBits = 32 - prefixLen;
  const blockSize = 2 ** hostBits;
  const networkAddress = Math.floor(addrInt / blockSize) * blockSize;
  const broadcastAddress = networkAddress + blockSize - 1;
  return { networkAddress, broadcastAddress, prefixLen };
}
__name(parseNetwork, "parseNetwork");
function networkStrFromInt(addrInt, prefixLen) {
  const hostBits = 32 - prefixLen;
  const blockSize = 2 ** hostBits;
  const networkAddress = Math.floor(addrInt / blockSize) * blockSize;
  return `${intToIp(networkAddress)}/${prefixLen}`;
}
__name(networkStrFromInt, "networkStrFromInt");
function bitLength(n) {
  if (n === 0)
    return 0;
  return n.toString(2).length;
}
__name(bitLength, "bitLength");

// src/utils.ts
function findAllDescendantsRecursive(parentKey, allNodes, foundKeys) {
  const directChildren = allNodes.filter((node) => node["group"] === parentKey);
  for (const child of directChildren) {
    const childKey = child.key;
    if (childKey && !foundKeys.has(childKey)) {
      foundKeys.add(childKey);
      findAllDescendantsRecursive(childKey, allNodes, foundKeys);
    }
  }
}
__name(findAllDescendantsRecursive, "findAllDescendantsRecursive");
function getNodesInGroup(startNodeKey, allNodes) {
  if (!startNodeKey || allNodes.length === 0)
    return [];
  const groupNodeKeys = /* @__PURE__ */ new Set([startNodeKey]);
  findAllDescendantsRecursive(startNodeKey, allNodes, groupNodeKeys);
  return allNodes.filter((node) => node.key != null && groupNodeKeys.has(node.key));
}
__name(getNodesInGroup, "getNodesInGroup");
function findAncestorByType(startNode, targetType, nodeMap) {
  let currentNode = startNode;
  for (let i = 0; i < 20; i++) {
    const parentKey = currentNode["group"];
    if (!parentKey)
      return null;
    const parentNode = nodeMap[parentKey];
    if (!parentNode)
      return null;
    if (parentNode.type === targetType)
      return parentNode;
    currentNode = parentNode;
  }
  return null;
}
__name(findAncestorByType, "findAncestorByType");
function sanitizeToKebabCase(name) {
  if (!name)
    return "default-path";
  const s1 = String(name).replace(/(.)([A-Z][a-z]+)/g, "$1-$2");
  const s2 = s1.replace(/([a-z0-9])([A-Z])/g, "$1-$2");
  return s2.replace(/[_\s]+/g, "-").toLowerCase().replace(/^-+|-+$/g, "");
}
__name(sanitizeToKebabCase, "sanitizeToKebabCase");
function findAccountAndRegionName(startNode, nodeMap) {
  let regionName = "";
  let accountId = "";
  const regionNode = findAncestorByType(startNode, "aws_region_", nodeMap);
  if (regionNode) {
    regionName = regionNode.cloudResource?.params?.["region_name"] ?? "";
    const cloudNode = findAncestorByType(regionNode, "aws_cloud_", nodeMap);
    if (cloudNode) {
      accountId = cloudNode.cloudResource?.params?.["account_id"] ?? "";
    }
  }
  return [accountId, regionName];
}
__name(findAccountAndRegionName, "findAccountAndRegionName");
function normalizePath(path) {
  if (!path)
    return "";
  let normalized = path.replace(/\\/g, "/");
  normalized = normalized.replace(/\/+/g, "/");
  return normalized.trim().replace(/\/+$/, "");
}
__name(normalizePath, "normalizePath");
function findAllRecursiveConnections(startNodeKey, targetTypes, nodeMap, direction = "source", visited = /* @__PURE__ */ new Set()) {
  if (visited.has(startNodeKey))
    return [];
  visited.add(startNodeKey);
  const node = nodeMap[startNodeKey];
  if (!node)
    return [];
  const foundNodes = [];
  const connections = node.connections?.[direction] ?? {};
  for (const [cType, cIds] of Object.entries(connections)) {
    for (const nextNodeId of cIds) {
      if (targetTypes.includes(cType)) {
        const targetNode = nodeMap[nextNodeId];
        if (targetNode && !foundNodes.includes(targetNode))
          foundNodes.push(targetNode);
      }
      const deepResults = findAllRecursiveConnections(nextNodeId, targetTypes, nodeMap, direction, visited);
      for (const r of deepResults)
        if (!foundNodes.includes(r))
          foundNodes.push(r);
    }
  }
  return foundNodes;
}
__name(findAllRecursiveConnections, "findAllRecursiveConnections");

// src/awsProviderLogic.ts
function createStateRankMap(payload) {
  const executionOrder = payload.executionOrder ?? [];
  const map = {};
  executionOrder.forEach((tfId, index) => {
    map[tfId] = index;
  });
  return map;
}
__name(createStateRankMap, "createStateRankMap");
function isPlainObject2(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}
__name(isPlainObject2, "isPlainObject");
function deepEqual(a, b) {
  if (a === b)
    return true;
  if (a === null || b === null)
    return a === b;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length)
      return false;
    return a.every((v, i) => deepEqual(v, b[i]));
  }
  if (typeof a === "object" && typeof b === "object") {
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    if (ka.length !== kb.length)
      return false;
    return ka.every(
      (k) => Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k])
    );
  }
  return false;
}
__name(deepEqual, "deepEqual");
function pyTruthy(v) {
  if (v === null || v === void 0 || v === false)
    return false;
  if (v === "" || v === 0)
    return false;
  if (Array.isArray(v))
    return v.length > 0;
  if (typeof v === "object")
    return Object.keys(v).length > 0;
  return Boolean(v);
}
__name(pyTruthy, "pyTruthy");
function pyCapitalize(s) {
  if (s.length === 0)
    return s;
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
}
__name(pyCapitalize, "pyCapitalize");
function pyIsalnumFilter(s) {
  let out = "";
  for (const ch of s)
    if (/[\p{L}\p{N}]/u.test(ch))
      out += ch;
  return out;
}
__name(pyIsalnumFilter, "pyIsalnumFilter");
function pyJsonString(s) {
  let out = '"';
  for (const ch of s) {
    const code = ch.codePointAt(0);
    if (ch === '"')
      out += '\\"';
    else if (ch === "\\")
      out += "\\\\";
    else if (ch === "\n")
      out += "\\n";
    else if (ch === "\r")
      out += "\\r";
    else if (ch === "	")
      out += "\\t";
    else if (ch === "\b")
      out += "\\b";
    else if (ch === "\f")
      out += "\\f";
    else if (code < 32 || code > 126) {
      if (code > 65535) {
        const c = code - 65536;
        const hi = 55296 + (c >> 10);
        const lo = 56320 + (c & 1023);
        out += "\\u" + hi.toString(16).padStart(4, "0") + "\\u" + lo.toString(16).padStart(4, "0");
      } else {
        out += "\\u" + code.toString(16).padStart(4, "0");
      }
    } else
      out += ch;
  }
  return out + '"';
}
__name(pyJsonString, "pyJsonString");
function pyJsonDumps(value) {
  if (value === null || value === void 0)
    return "null";
  if (typeof value === "boolean")
    return value ? "true" : "false";
  if (typeof value === "number")
    return String(value);
  if (typeof value === "string")
    return pyJsonString(value);
  if (Array.isArray(value))
    return "[" + value.map((v) => pyJsonDumps(v)).join(", ") + "]";
  if (typeof value === "object") {
    const keys = Object.keys(value).sort();
    return "{" + keys.map((k) => pyJsonString(k) + ": " + pyJsonDumps(value[k])).join(", ") + "}";
  }
  return "null";
}
__name(pyJsonDumps, "pyJsonDumps");
function pyOr(...vals) {
  for (let i = 0; i < vals.length - 1; i++) {
    if (pyTruthy(vals[i]))
      return vals[i];
  }
  return vals[vals.length - 1];
}
__name(pyOr, "pyOr");
function removeFirst(arr, value) {
  const idx = arr.indexOf(value);
  if (idx !== -1)
    arr.splice(idx, 1);
}
__name(removeFirst, "removeFirst");
var AwsProviderLogic = class {
  hcl;
  generatedNodes = [];
  stateNameMap = {};
  activeProviders = /* @__PURE__ */ new Set(["aws"]);
  dynamicProviderConfigs = {};
  providerDefinitions = {
    aws: { source: "hashicorp/aws", version: ">= 5.0" },
    archive: { source: "hashicorp/archive", version: ">= 2.4.2" },
    http: { source: "hashicorp/http", version: "~> 3.4.0" },
    tls: { source: "hashicorp/tls", version: "~> 4.0" },
    random: { source: "hashicorp/random", version: "~> 3.5.1" },
    helm: { source: "hashicorp/helm", version: "~> 2.12.1" },
    kubernetes: { source: "hashicorp/kubernetes", version: "~> 2.24.0" },
    datadog: { source: "datadog/datadog", version: "~> 3.0" }
  };
  resourceToProviderMap = {
    archive_file: "archive",
    http: "http",
    random_string: "random",
    random_id: "random",
    tls_certificate: "tls"
  };
  // --- Estado por requisicao (globais de modulo promovidas a instancia) ---
  // `node` é o "node atual" que o dispatch (process_nodes/pre_process_nodes) seta
  // antes de chamar cada handler handle_{tipo} -- os handlers o leem como global.
  node = null;
  nodeMap = null;
  payload = {};
  domainNodeKeys = [];
  terraformKey = null;
  stateRankMap = {};
  // Global `nodes` do Python (= payload["nodes"]); usada por _create_alias_record
  // e outros handlers como target_list de add_generic_node.
  nodes = [];
  // Coletor de erros/warnings de validação (equivalente ao singleton `collector`
  // do Python message_collector; instância por logic pra isolamento em teste).
  collector = new MessageCollector();
  // Injetavel para permitir determinismo em teste (oraculo Python usa uuid4
  // monkeypatchado); em producao gera UUID real via node:crypto.
  idGenerator = () => randomUUID();
  // Estado do handler aws_network_acl (getattr(self, "_nacl_prescan_done", False)
  // no Python): garante que o prescan global das NACLs rode uma única vez por
  // execução do pipeline.
  naclPrescanDone = false;
  constructor(hclCore) {
    this.hcl = hclCore;
  }
  // Port de update_context (00_prologue.py) + as duas primeiras linhas de
  // process_nodes/pre_process_nodes que computam state_rank_map -- unificado
  // aqui num unico ponto de entrada por requisicao.
  setContext(payload, domainNodeKeys, terraformKey, nodeMap) {
    this.payload = payload;
    this.domainNodeKeys = domainNodeKeys;
    this.terraformKey = terraformKey;
    this.nodeMap = nodeMap;
    this.stateRankMap = createStateRankMap(payload);
    this.nodes = payload.nodes ?? [];
  }
  // Port de add_generic_node (core/10_shared.py). Cria um novo node e decide
  // a qual state (terraformKey) ele pertence, com base em qual dos nos
  // source/target o state atual possui e no ranking de execucao entre states.
  // Efeitos colaterais (fieis ao original): alem de retornar o node, apenda
  // em targetList/domainNodeKeys/nodeMap e MUTA sourceNode/targetNode in-place
  // (liga connections nos dois sentidos).
  addGenericNode(targetList, resourceType, logicalName, sourceNode = null, targetNode = null, forceCreate = false) {
    const key = this.idGenerator();
    const newNode = {
      key,
      type: resourceType,
      logicalName,
      cloudResource: { params: { tags: {} } },
      connections: { source: {}, target: {} }
    };
    const srcId = sourceNode ? sourceNode.terraformID ?? null : null;
    const tgtId = targetNode ? targetNode.terraformID ?? null : null;
    let selectedTerraformId = this.terraformKey;
    let shouldSkip = false;
    if (!forceCreate) {
      if (sourceNode && targetNode) {
        if (this.terraformKey !== srcId && this.terraformKey !== tgtId)
          shouldSkip = true;
      } else if (sourceNode) {
        if (this.terraformKey !== srcId)
          shouldSkip = true;
      } else if (targetNode) {
        if (this.terraformKey !== tgtId)
          shouldSkip = true;
      }
    }
    if (shouldSkip)
      return null;
    if (forceCreate) {
      selectedTerraformId = this.terraformKey;
    } else {
      const srcRank = srcId ? this.stateRankMap[srcId] ?? -1 : -1;
      const tgtRank = tgtId ? this.stateRankMap[tgtId] ?? -1 : -1;
      if (sourceNode || targetNode) {
        if (sourceNode && targetNode) {
          selectedTerraformId = srcRank >= tgtRank ? srcId : tgtId;
        } else if (sourceNode) {
          selectedTerraformId = srcId;
        } else if (targetNode) {
          selectedTerraformId = tgtId;
        }
      }
    }
    if (selectedTerraformId) {
      newNode.terraformID = selectedTerraformId;
    }
    let shouldCreate = false;
    if (forceCreate) {
      shouldCreate = true;
    } else if (sourceNode === null && targetNode === null) {
      shouldCreate = true;
    } else if (selectedTerraformId === this.terraformKey) {
      shouldCreate = true;
    }
    if (!shouldCreate)
      return null;
    if (sourceNode) {
      const srcType = sourceNode.type;
      const srcKey = sourceNode.key;
      if (srcType && srcKey) {
        newNode.connections.source[srcType] ??= [];
        newNode.connections.source[srcType].push(srcKey);
        sourceNode.connections ??= {};
        sourceNode.connections.target ??= {};
        sourceNode.connections.target[resourceType] ??= [];
        if (!sourceNode.connections.target[resourceType].includes(key)) {
          sourceNode.connections.target[resourceType].push(key);
        }
      }
    }
    if (targetNode) {
      const tgtType = targetNode.type;
      const tgtKey = targetNode.key;
      if (tgtType && tgtKey) {
        newNode.connections.target[tgtType] ??= [];
        newNode.connections.target[tgtType].push(tgtKey);
        targetNode.connections ??= {};
        targetNode.connections.source ??= {};
        targetNode.connections.source[resourceType] ??= [];
        if (!targetNode.connections.source[resourceType].includes(key)) {
          targetNode.connections.source[resourceType].push(key);
        }
      }
    }
    targetList.push(newNode);
    this.domainNodeKeys.push(key);
    if (this.nodeMap !== null) {
      this.nodeMap[key] = newNode;
    }
    return newNode;
  }
  // Port de register_required_provider (core/10_shared.py). Ativa um provider
  // no header se o tipo do recurso exigir (ex.: archive_file -> archive).
  registerRequiredProvider(resourceType) {
    const providerName = this.resourceToProviderMap[resourceType];
    if (providerName) {
      this.activeProviders.add(providerName);
    }
  }
  // Port de add_generic_data_source (core/10_shared.py). Garante um container
  // global de data sources no início de targetList e adiciona uma entry,
  // deduplicada por XTYPE + logicalName + params (comparação profunda
  // ordem-insensível, como o dict == do Python). Muta domainNodeKeys.
  addGenericDataSource(targetList, resourceType, logicalName, params = null) {
    const resolvedParams = params && Object.keys(params).length > 0 ? params : {};
    const CONTAINER_TYPE = "system_global_datasource_container";
    if (targetList.length === 0 || targetList[0].type !== CONTAINER_TYPE) {
      const containerKey = this.idGenerator();
      const container = { key: containerKey, type: CONTAINER_TYPE, entries: [] };
      targetList.unshift(container);
      if (!this.domainNodeKeys.includes(containerKey))
        this.domainNodeKeys.push(containerKey);
    }
    const containerNode = targetList[0];
    if (!this.domainNodeKeys.includes(containerNode.key)) {
      this.domainNodeKeys.push(containerNode.key);
    }
    for (const entry of containerNode.entries) {
      if (entry.XTYPE === resourceType && entry.logicalName === logicalName && deepEqual(entry.params, resolvedParams)) {
        return entry;
      }
    }
    const newEntry = { key: this.idGenerator(), XTYPE: resourceType, logicalName, params: resolvedParams };
    containerNode.entries.push(newEntry);
    return newEntry;
  }
  // Port de _process_payload_env_vars (core/10_shared.py). Extrai as env vars
  // já processadas pelo frontend e REMOVE a chave dos params (pra o gerador
  // dinâmico não emitir um bloco literal environment_variables {}). Muta o node.
  processPayloadEnvVars(node) {
    const params = node.cloudResource?.params ?? {};
    const raw = params["environment_variables"];
    const envVars = isPlainObject2(raw) ? raw : {};
    if (Object.prototype.hasOwnProperty.call(params, "environment_variables")) {
      delete params["environment_variables"];
    }
    return envVars;
  }
  // Port de get_connected_network_context (core/10_shared.py). Recebe node_map
  // explícito (não usa estado global). Mapeia as subnets conectadas ao
  // start_node, suas AZs e se o contexto é multi-AZ.
  // NOTA: az_names deriva de um set() no Python, cuja ordem é randomizada por
  // processo -- não é semanticamente significativa; o teste compara ordenado.
  getConnectedNetworkContext(startNode, nodeMap) {
    let regionName = "";
    for (const n of Object.values(nodeMap)) {
      if (n.type === "aws_region_") {
        regionName = n.cloudResource?.params?.region_name ?? "";
        break;
      }
    }
    const targetConnections = startNode.connections?.target ?? {};
    const subnetKeys = targetConnections["aws_subnet"] ?? [];
    const subnetNodes = [];
    const azNodes = [];
    const seenAzKeys = /* @__PURE__ */ new Set();
    const azNames = /* @__PURE__ */ new Set();
    for (const subnetKey of subnetKeys) {
      const subnetNode = nodeMap[subnetKey];
      if (subnetNode) {
        subnetNodes.push(subnetNode);
        const subAzKeys = subnetNode.connections?.target?.["aws_az_"] ?? [];
        for (const azKey of subAzKeys) {
          const azNode = nodeMap[azKey];
          if (azNode) {
            if (!seenAzKeys.has(azKey)) {
              seenAzKeys.add(azKey);
              azNodes.push(azNode);
            }
            const azSuffix = azNode.cloudResource?.params?.az_suffix ?? "";
            if (regionName && azSuffix) {
              azNames.add(`${regionName}${azSuffix}`);
            }
          }
        }
      }
    }
    return {
      subnet_nodes: subnetNodes,
      subnet_logical_names: subnetNodes.map((s) => s.logicalName ?? null),
      az_nodes: azNodes,
      az_names: [...azNames],
      is_multi_az: azNames.size > 1,
      region_name: regionName
    };
  }
  // Port de _resolve_dns_hierarchy_iterative (core/10_shared.py). Sobe a árvore
  // de zonas/subdomínios reconstruindo o FQDN. Puro (node_map explícito, sem
  // mutação). Retorna [fullDomain, rootLogicalName].
  resolveDnsHierarchyIterative(startNode, nodeMap) {
    const prefixes = [];
    let currentNode = startNode;
    let rootLogicalName = null;
    let rootDomainName = "";
    for (let i = 0; i < 100; i++) {
      const params = currentNode.cloudResource?.params ?? {};
      const src = currentNode.connections?.source ?? {};
      const parents = [...src["aws_route53_zone"] ?? [], ...src["cldmn_subdomain"] ?? []];
      let segmentName = params["subdomain"];
      if (!segmentName)
        segmentName = params["subdomain_prefix_"] ?? "";
      if (parents.length === 0) {
        rootLogicalName = currentNode.logicalName ?? null;
        rootDomainName = segmentName ? segmentName : params["name"] ?? "";
        break;
      }
      if (segmentName)
        prefixes.push(segmentName);
      const parentKey = parents[0];
      const parentNode = nodeMap[parentKey];
      if (!parentNode)
        return ["", null];
      currentNode = parentNode;
    }
    const fullNameParts = [...prefixes, rootDomainName].filter((p) => p);
    return [fullNameParts.join("."), rootLogicalName];
  }
  // Port de _yield_dns_context (core/10_shared.py). O original é um generator
  // Python; aqui retorna um array. Puro (node_map explícito). Resolve cada
  // conexão DNS (zona/subdomínio) e devolve só as que resolvem para um FQDN + raiz.
  yieldDnsContext(node, nodeMap) {
    const source = node.connections?.source ?? {};
    const r53Keys = source["aws_route53_zone"] ?? [];
    const subdomainKeys = source["cldmn_subdomain"] ?? [];
    const allKeys = [...r53Keys, ...subdomainKeys];
    const out = [];
    for (const key of allKeys) {
      const dnsNode = nodeMap[key];
      if (!dnsNode)
        continue;
      const [fullDomain, resolvedRoot] = this.resolveDnsHierarchyIterative(dnsNode, nodeMap);
      const rootId = resolvedRoot ?? dnsNode.rootLogicalName ?? null;
      if (fullDomain && rootId)
        out.push({ key, dnsNode, fullDomain, rootId });
    }
    return out;
  }
  // Port de _create_alias_record (core/10_shared.py). USA as globais nodes/
  // nodeMap (aqui campos de instância) e chama addGenericNode. Coleta o domínio
  // principal + os SANs do ACM conectado, dedup por Set + sorted, e cria um
  // aws_route53_record (Alias) por domínio. Muta nodes/domainNodeKeys/nodeMap e
  // os nós de origem/destino.
  createAliasRecord(dnsNode, targetNode, rootId, fullDomain, targetConfig, recordType = "A") {
    const targetType = targetNode.type;
    const targetLogicalName = targetConfig.logical_name;
    const rawDomains = [fullDomain];
    const dnsTargets = dnsNode.connections?.target ?? {};
    const acmKeys = dnsTargets["aws_acm_certificate"] ?? [];
    for (const acmKey of acmKeys) {
      const acmNode = this.nodeMap?.[acmKey];
      if (acmNode) {
        const acmParams = acmNode.cloudResource?.params ?? {};
        const sansRaw = acmParams["subject_alternative_names"];
        let sans;
        if (typeof sansRaw === "string" && sansRaw)
          sans = [sansRaw];
        else if (Array.isArray(sansRaw))
          sans = sansRaw;
        else
          sans = [];
        for (const san of sans)
          if (san)
            rawDomains.push(san);
      }
    }
    const uniqueDomains = /* @__PURE__ */ new Set();
    for (const domain2 of rawDomains) {
      let clean = domain2.trim().toLowerCase();
      if (clean.endsWith("."))
        clean = clean.slice(0, -1);
      uniqueDomains.add(clean);
    }
    const domainsToProcess = [...uniqueDomains].sort();
    const createdRecords = [];
    for (const domain2 of domainsToProcess) {
      const domainSuffix = domain2.replace(/\./g, "_").replace(/\*/g, "wildcard");
      const recordLogical = `alias_${recordType.toLowerCase()}_${targetType}_${targetLogicalName}_${domainSuffix}`;
      const existingNode = this.nodes.find((n) => n.logicalName === recordLogical) ?? null;
      if (existingNode) {
        if (!createdRecords.includes(existingNode))
          createdRecords.push(existingNode);
        continue;
      }
      const recordParams = {
        zone_id: `aws_route53_zone.${rootId}.zone_id`,
        name: domain2,
        type: recordType,
        alias: [
          {
            name: targetConfig.dns_name_ref,
            zone_id: targetConfig.zone_id_ref,
            evaluate_target_health: targetConfig.evaluate_target_health
          }
        ]
      };
      const createdRecord = this.addGenericNode(this.nodes, "aws_route53_record", recordLogical, dnsNode, targetNode);
      if (createdRecord) {
        createdRecord.cloudResource = createdRecord.cloudResource ?? {};
        createdRecord.cloudResource.params = recordParams;
        const srcType = dnsNode.type;
        createdRecord.connections = createdRecord.connections ?? { source: {}, target: {} };
        createdRecord.connections.source = { [srcType]: [dnsNode.id ?? null] };
        createdRecords.push(createdRecord);
      }
    }
    return createdRecords;
  }
  // Port de _calcular_spanning_cidr (core/10_shared.py). Menor bloco CIDR comum
  // (alargado) que contém todas as subnets, mesmo com gaps. Puro.
  calcularSpanningCidr(subnetKeys, nodeMap) {
    const cidrs = [];
    for (const skey of subnetKeys) {
      const cidr = nodeMap[skey]?.cloudResource?.params?.cidr_block;
      if (cidr)
        cidrs.push(cidr);
    }
    if (cidrs.length === 0)
      return "0.0.0.0/0";
    if (cidrs.length === 1)
      return cidrs[0];
    const networks = cidrs.map(parseNetwork);
    const minIp = Math.min(...networks.map((n) => n.networkAddress));
    const maxIp = Math.max(...networks.map((n) => n.broadcastAddress));
    const xorDiff = (minIp ^ maxIp) >>> 0;
    const diffBits = bitLength(xorDiff);
    const prefixLen = 32 - diffBits;
    return networkStrFromInt(minIp, prefixLen);
  }
  // Port de _gerar_tf_cidr (core/10_shared.py). Gera a expressão Terraform
  // cidrsubnet() a partir do CIDR alargado e da VPC dona (achada no node_map).
  gerarTfCidr(spanningCidrStr, node, nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const vpcIdRef = params["vpc_id"] ?? "aws_vpc.vpc-bp-admin.id";
    const vpcLogical = vpcIdRef.replaceAll("data.", "").replaceAll("aws_vpc.", "").replaceAll(".id", "");
    const vpcNode = Object.values(nodeMap).find((v) => v.type === "aws_vpc" && v.logicalName === vpcLogical);
    const vpcCidr = vpcNode.cloudResource.params.cidr_block;
    const vpcNet = parseNetwork(vpcCidr);
    const spanNet = parseNetwork(spanningCidrStr);
    const newbits = spanNet.prefixLen - vpcNet.prefixLen;
    const netnum = Math.floor((spanNet.networkAddress - vpcNet.networkAddress) / 2 ** (32 - spanNet.prefixLen));
    const vpcPrefix = vpcIdRef.includes("data.") ? "data.aws_vpc" : "aws_vpc";
    return `\${cidrsubnet(${vpcPrefix}.${vpcLogical}.cidr_block, ${newbits}, ${netnum})}`;
  }
  // Port de _allocate_rule_number (core/10_shared.py). Aloca um rule_number único
  // pra uma regra de NACL, varrendo o cache local do nó, reservas explícitas do
  // usuário, e a memória global do gerador (this.generatedNodes). Muta naclNode.
  allocateRuleNumber(naclNode, isEgress, startNumber = 100, currentNodeId = null) {
    if (!naclNode)
      return startNumber;
    const direction = isEgress ? "egress" : "ingress";
    const naclLogicalName = naclNode.logicalName;
    const targetAclIdStr = `aws_network_acl.${naclLogicalName}.id`;
    naclNode["_allocated_rules"] ??= {};
    naclNode["_allocated_rules"][direction] ??= [];
    const allocated = naclNode["_allocated_rules"][direction];
    naclNode["_explicit_rules"] ??= {};
    naclNode["_explicit_rules"][direction] ??= {};
    const explicit = naclNode["_explicit_rules"][direction];
    let ruleNumber = startNumber;
    while (true) {
      if (allocated.includes(ruleNumber)) {
        ruleNumber += 1;
        continue;
      }
      const claimedBy = explicit[ruleNumber];
      if (claimedBy != null && claimedBy !== currentNodeId) {
        ruleNumber += 1;
        continue;
      }
      let alreadyTakenGlobally = false;
      for (const genNode of this.generatedNodes) {
        if (genNode.type === "aws_network_acl_rule") {
          const gParams = genNode.cloudResource?.params ?? {};
          const gNaclId = gParams["network_acl_id"] ?? "";
          const gEgress = gParams["egress"] ?? false;
          const gNum = gParams["rule_number"];
          if (gNaclId === targetAclIdStr && gEgress === isEgress && gNum === ruleNumber) {
            alreadyTakenGlobally = true;
            break;
          }
        }
      }
      if (alreadyTakenGlobally) {
        ruleNumber += 1;
        continue;
      }
      break;
    }
    allocated.push(ruleNumber);
    return ruleNumber;
  }
  // Port de _extract_resource_name_hint (core/10_shared.py). Extrai um nome
  // legível de uma interpolação Terraform ou ARN, pra gerar SID de IAM. Puro.
  extractResourceNameHint(resourceStr) {
    if (resourceStr === "*")
      return "AllResources";
    if (resourceStr.includes("${") && resourceStr.includes("}")) {
      const clean = resourceStr.replaceAll("${", "").replaceAll("}", "");
      const parts = clean.split(".");
      if (parts.length >= 2)
        return pyCapitalize(parts[1]);
    }
    if (resourceStr.includes("arn:aws:")) {
      const parts = resourceStr.split(":");
      if (parts.length > 0) {
        const lastPart = parts[parts.length - 1];
        return pyCapitalize(lastPart.split("/").pop().split("-")[0]);
      }
    }
    return "Resource";
  }
  // Port de _optimize_policy_statements (core/10_shared.py). ALTO RISCO DE
  // SEGURANÇA: mescla statements com Effect/Resources/Condition/Principals
  // idênticos consolidando as Actions, e garante SIDs únicos. Um bug aqui pode
  // ALARGAR permissão (mesclar o que não deveria) -- por isso os testes cobrem
  // explicitamente os casos de NÃO-merge (effect/resource/condition diferentes).
  optimizePolicyStatements(statements) {
    if (!statements || statements.length === 0)
      return [];
    const groupedMap = /* @__PURE__ */ new Map();
    for (const stmt of statements) {
      const effect = stmt["effect"] ?? "Allow";
      let resources = stmt["resources"] ?? [];
      if (typeof resources === "string")
        resources = [resources];
      const resourcesSorted = [...new Set(resources)].sort();
      let actions = stmt["actions"] ?? [];
      if (typeof actions === "string")
        actions = [actions];
      const actionsSet = new Set(actions);
      const condition = stmt["condition"] ?? {};
      const principal = stmt["principals"] ?? {};
      const keyTuple = [effect, pyJsonDumps(resourcesSorted), pyJsonDumps(condition), pyJsonDumps(principal)].join("\0");
      const existing = groupedMap.get(keyTuple);
      if (existing) {
        for (const a of actionsSet)
          existing.actions.add(a);
        const currentSid = stmt["sid"];
        if (currentSid && !existing.sid)
          existing.sid = currentSid;
      } else {
        groupedMap.set(keyTuple, {
          effect,
          resources: resourcesSorted,
          condition,
          principals: principal,
          actions: actionsSet,
          sid: stmt["sid"] ?? ""
        });
      }
    }
    const finalStatements = [];
    const usedSids = /* @__PURE__ */ new Set();
    const sortedKeys = [...groupedMap.keys()].sort();
    for (const key of sortedKeys) {
      const group3 = groupedMap.get(key);
      const newStmt = {
        effect: group3.effect,
        actions: [...group3.actions].sort(),
        resources: group3.resources
      };
      if (pyTruthy(group3.condition))
        newStmt.condition = group3.condition;
      if (pyTruthy(group3.principals))
        newStmt.principals = group3.principals;
      const rawSid = group3.sid ?? "";
      let finalSid = rawSid ? pyIsalnumFilter(rawSid) : "";
      if (!finalSid || usedSids.has(finalSid)) {
        let resourceHint = "Statement";
        if (group3.resources && group3.resources.length > 0) {
          const firstRes = group3.resources[0];
          const rawHint = this.extractResourceNameHint(firstRes);
          resourceHint = pyIsalnumFilter(rawHint) || "Statement";
        }
        const base = finalSid ? finalSid : `Allow${resourceHint}`;
        let counter = 1;
        let candidate = base;
        while (usedSids.has(candidate)) {
          if (counter === 1 && !rawSid) {
            candidate = `Allow${resourceHint}`;
            if (usedSids.has(candidate))
              candidate = `Allow${resourceHint}${counter}`;
          } else {
            candidate = `${base}${counter}`;
          }
          counter += 1;
        }
        finalSid = candidate;
      }
      if (finalSid) {
        newStmt.sid = finalSid;
        usedSids.add(finalSid);
      }
      finalStatements.push(newStmt);
    }
    return finalStatements;
  }
  // Port de _collect_policy_statements (core/10_shared.py). Extrai e normaliza
  // statements de um nó de policy (do raw_json_/policy_json OU do params.statement,
  // nunca dos dois). Puro. Retorna [normalizados, key do nó].
  collectPolicyStatements(pNode) {
    const collected = [];
    const params = pNode.cloudResource?.params ?? {};
    const rawJsonStr = pyOr(params["raw_json_"], params["policy_json"]);
    if (rawJsonStr && typeof rawJsonStr === "string" && rawJsonStr.trim()) {
      try {
        const data = JSON.parse(rawJsonStr);
        const stmts = data["Statement"] ?? [];
        if (Array.isArray(stmts))
          collected.push(...stmts);
        else if (isPlainObject2(stmts))
          collected.push(stmts);
      } catch {
      }
    }
    if (collected.length === 0) {
      const paramsStmts = params["statement"];
      if (pyTruthy(paramsStmts)) {
        if (Array.isArray(paramsStmts))
          collected.push(...paramsStmts);
        else if (isPlainObject2(paramsStmts))
          collected.push(paramsStmts);
      }
    }
    const normalized = [];
    for (const stmt of collected) {
      if (!pyTruthy(stmt))
        continue;
      const nStmt = {};
      nStmt.effect = pyOr(stmt["Effect"], stmt["effect"], "Allow");
      const act = pyOr(stmt["Action"], stmt["Actions"], stmt["action"], stmt["actions"], []);
      nStmt.actions = typeof act === "string" ? [act] : act;
      if (nStmt.actions == null)
        nStmt.actions = [];
      let res = pyOr(stmt["Resource"], stmt["Resources"], stmt["resource"], stmt["resources"]);
      if (res == null)
        res = ["*"];
      nStmt.resources = typeof res === "string" ? [res] : res;
      const sid = pyOr(stmt["Sid"], stmt["sid"]);
      if (pyTruthy(sid))
        nStmt.sid = sid;
      const cond = pyOr(stmt["Condition"], stmt["condition"]);
      if (pyTruthy(cond))
        nStmt.condition = cond;
      const princ = pyOr(stmt["Principal"], stmt["principal"]);
      if (pyTruthy(princ))
        nStmt.principals = princ;
      normalized.push(nStmt);
    }
    return [normalized, pNode.key];
  }
  // Port de _find_role_reference (core/10_shared.py). Acha a referência da Role
  // (nome ou HCL ref) associada a um recurso, cobrindo: forced_role_ref no
  // metadata, match por role_index, params.role direto, e a cadeia via Instance
  // Profile (3 sub-casos). Puro (só leitura). Retorna string ou null.
  findRoleReference(sourceNode, nodeMap, policyNode = null) {
    if (policyNode) {
      const meta = policyNode["_internal_metadata"] ?? {};
      const forcedRef = meta["forced_role_ref"];
      if (forcedRef)
        return forcedRef;
    }
    let targetIndex = 0;
    if (policyNode) {
      const meta = policyNode["_internal_metadata"] ?? {};
      targetIndex = meta["role_index"] ?? 0;
    }
    const roleKeys = sourceNode.connections?.source?.["aws_iam_role"] ?? [];
    if (roleKeys.length === 0) {
      const params = sourceNode.cloudResource?.params ?? {};
      const roleParam = pyOr(params["role"], params["iam_role"]);
      if (roleParam && typeof roleParam === "string" && roleParam.includes("aws_iam_role")) {
        return roleParam;
      }
      const profileKeys = sourceNode.connections?.source?.["aws_iam_instance_profile"] ?? [];
      for (const pKey of profileKeys) {
        const profileNode = nodeMap[pKey];
        if (!profileNode)
          continue;
        const profileParams = profileNode.cloudResource?.params ?? {};
        const embeddedRole = profileParams["aws_iam_role"];
        if (isPlainObject2(embeddedRole)) {
          const embeddedRoleRef = pyOr(embeddedRole["originalLogicalName_"], embeddedRole["name"]);
          if (embeddedRoleRef)
            return embeddedRoleRef;
        }
        const roleParamP = pyOr(profileParams["role"], profileParams["iam_role"]);
        if (roleParamP && typeof roleParamP === "string") {
          const match = roleParamP.match(/aws_iam_role\.([A-Za-z0-9_\-]+)/);
          if (match)
            return match[1];
        }
        const profileRoleKeys = profileNode.connections?.source?.["aws_iam_role"] ?? [];
        for (const rKey of profileRoleKeys) {
          const rNode = nodeMap[rKey];
          if (rNode && rNode.logicalName)
            return rNode.logicalName;
        }
      }
      return null;
    }
    let selectedRole = null;
    for (const rKey of roleKeys) {
      const rNode = nodeMap[rKey];
      if (!rNode)
        continue;
      const rMeta = rNode["_internal_metadata"] ?? {};
      const rIndex = rMeta["role_index"] ?? 0;
      if (rIndex === targetIndex) {
        selectedRole = rNode;
        break;
      }
    }
    if (selectedRole) {
      const roleName = selectedRole.cloudResource?.params?.["name"];
      if (roleName)
        return roleName;
      return `aws_iam_role.${selectedRole.logicalName}.name`;
    }
    return null;
  }
  // Port de _bypass_visual_connection (core/10_shared.py). Reconecta
  // Identity -> Resource removendo a Policy intermediária. Usa this.nodeMap
  // (global node_map). MUTA identity_node e os target nodes.
  bypassVisualConnection(identityNode, policyNode) {
    const policyTargets = policyNode.connections?.target ?? {};
    const identityTargets = identityNode.connections?.target ?? {};
    if (identityTargets["aws_iam_policy"]?.includes(policyNode.key)) {
      removeFirst(identityTargets["aws_iam_policy"], policyNode.key);
    }
    if (identityTargets["cldmn_policy"]?.includes(policyNode.key)) {
      removeFirst(identityTargets["cldmn_policy"], policyNode.key);
    }
    for (const [tType, tIds] of Object.entries(policyTargets)) {
      for (const tId of tIds) {
        const targetNode = this.nodeMap?.[tId];
        if (!targetNode)
          continue;
        if (!(tType in identityTargets))
          identityTargets[tType] = [];
        if (!identityTargets[tType].includes(tId))
          identityTargets[tType].push(tId);
        const targetConnections = targetNode.connections ?? {};
        targetConnections.source ??= {};
        const tSources = targetConnections.source;
        const idType = identityNode.type;
        if (!(idType in tSources))
          tSources[idType] = [];
        if (!tSources[idType].includes(identityNode.key))
          tSources[idType].push(identityNode.key);
      }
    }
  }
  // Port de _create_dynamic_policy (core/10_shared.py). Cria um aws_iam_policy
  // via add_generic_node, injeta os statements, marca __isGenerated e cria o
  // vínculo reverso parent -> policy (necessário pro preprocess_iam_policies achar).
  createDynamicPolicy(parentNode, policySuffix, statements) {
    const parentName = parentNode.logicalName ?? "Resource";
    const policyLogicalName = `Policy_${parentName}_${policySuffix}`;
    const newPolicyNode = this.addGenericNode(this.generatedNodes, "aws_iam_policy", policyLogicalName, parentNode);
    if (newPolicyNode) {
      newPolicyNode.cloudResource ??= {};
      newPolicyNode.cloudResource.params ??= {};
      newPolicyNode.cloudResource.params["statement"] = statements;
      newPolicyNode["__isGenerated"] = true;
      parentNode.connections ??= {};
      parentNode.connections.target ??= {};
      const parentTargets = parentNode.connections.target;
      if (!("aws_iam_policy" in parentTargets))
        parentTargets["aws_iam_policy"] = [];
      if (!parentTargets["aws_iam_policy"].includes(newPolicyNode.key))
        parentTargets["aws_iam_policy"].push(newPolicyNode.key);
    }
    return newPolicyNode;
  }
  // Port de add_managed_policy (core/10_shared.py). Localiza a Role (direta ou via
  // findRoleReference) e cria um aws_iam_role_policy_attachment pra uma managed
  // policy da AWS. Retorna null se não achar Role. (Os params state_rank_map/
  // terraform_key do original são mortos -- add_generic_node usa o estado da
  // instância; omitidos aqui.)
  addManagedPolicy(parentNode, policyName, nodeMap, directRoleRef = null) {
    const cleanPolicyName = policyName.replace(/[^a-zA-Z0-9_]/g, "_");
    const parentName = parentNode.logicalName ?? "Resource";
    const roleRef = directRoleRef || this.findRoleReference(parentNode, nodeMap);
    if (!roleRef)
      return null;
    const attachmentLogicalName = `${cleanPolicyName}_to_${parentName}_attach`;
    const attachmentNode = this.addGenericNode(
      this.generatedNodes,
      "aws_iam_role_policy_attachment",
      attachmentLogicalName,
      parentNode
    );
    if (attachmentNode) {
      const policyArn = `arn:aws:iam::aws:policy/${policyName}`;
      attachmentNode.cloudResource ??= {};
      attachmentNode.cloudResource.params = { role: `aws_iam_role.${roleRef}.name`, policy_arn: policyArn };
      attachmentNode["__isGenerated"] = true;
    }
    return attachmentNode;
  }
  // Port de preprocess_iam_policies (core/10_shared.py, ~550 linhas). ORQUESTRADOR
  // STATEFUL do IAM: coleta policies conectadas, agrupa/otimiza statements e gera
  // aws_iam_policy + document + attachment (identity-based) OU resource-based
  // policies (S3/SQS/SNS/KMS/CloudWatch), com 3 rotas (RB nativo / identity / RB
  // invertido), injeção de principals de serviço + condições, e um passe final de
  // depends_on. Usa/muta this.nodes/nodeMap/generatedNodes/domainNodeKeys +
  // this.collector. Retorna this.payload com payload.nodes reescrito.
  preprocessIamPolicies() {
    const resourceBasedMap = {
      aws_s3_bucket: "aws_s3_bucket_policy",
      aws_sqs_queue: "aws_sqs_queue_policy",
      aws_kms_key: "aws_kms_key_policy",
      aws_sns_topic: "aws_sns_topic_policy",
      aws_secretsmanager_secret: "aws_secretsmanager_secret_policy",
      aws_ecr_repository: "aws_ecr_repository_policy",
      aws_cloudwatch_event_bus: "aws_cloudwatch_event_bus_policy",
      aws_cloudwatch_log_group: "aws_cloudwatch_log_resource_policy"
    };
    const nodes = this.payload.nodes ?? [];
    this.nodes = nodes;
    this.stateNameMap = {};
    for (const n of nodes) {
      if (n.type === "cldmn_terraform")
        this.stateNameMap[n.key] = n.logicalName ?? "UnknownState";
    }
    const executionOrder = this.payload.executionOrder ?? [];
    this.stateRankMap = {};
    executionOrder.forEach((tfId, index) => {
      this.stateRankMap[tfId] = index;
    });
    const newNodesToAdd = [];
    const allRemovedPolicyIds = /* @__PURE__ */ new Set();
    const flushAttachment = /* @__PURE__ */ __name((attachmentNode) => {
      if (attachmentNode) {
        removeFirst(this.generatedNodes, attachmentNode);
        newNodesToAdd.push(attachmentNode);
      }
    }, "flushAttachment");
    const candidates = [];
    for (const node of nodes) {
      if (String(node.type ?? "").startsWith("kubernetes_"))
        continue;
      const targets = node.connections?.target ?? {};
      if ("aws_iam_policy" in targets || "cldmn_policy" in targets)
        candidates.push(node);
    }
    for (const pNode of [...nodes]) {
      if (pNode.type !== "aws_iam_policy" && pNode.type !== "cldmn_policy")
        continue;
      if (allRemovedPolicyIds.has(pNode.key))
        continue;
      const roleKeys = pNode.connections?.target?.["aws_iam_role"] ?? [];
      if (roleKeys.length === 0)
        continue;
      const roleNode = this.nodeMap?.[roleKeys[0]];
      if (!roleNode)
        continue;
      const managedPolicyName = pNode.cloudResource?.params?.["managed_policy_"];
      let didSomething = false;
      if (managedPolicyName) {
        const attachmentNode = this.addManagedPolicy(
          roleNode,
          managedPolicyName,
          this.nodeMap,
          roleNode.logicalName ?? null
        );
        flushAttachment(attachmentNode);
        didSomething = true;
      }
      const [stmts] = this.collectPolicyStatements(pNode);
      if (stmts.length > 0) {
        const isMissingActions = stmts.some((s) => !pyTruthy(s["actions"]));
        if (isMissingActions) {
          this.collector.addError(["iam_policy_missing_actions", pNode.key]);
        } else {
          const optimizedStatements = this.optimizePolicyStatements(stmts);
          const roleLogical = roleNode.logicalName ?? "Role";
          const roleStateId = roleNode.terraformID ?? this.terraformKey;
          const currentStateName = this.stateNameMap[roleStateId] ?? "UnknownState";
          const policyLogicalName = `policy_${roleLogical}_direct_st_${currentStateName}`;
          const docLogicalName = `${policyLogicalName}_doc`;
          const attachmentLogicalName = `${policyLogicalName}_attach`;
          const newPolicy = this.addGenericNode(nodes, "aws_iam_policy", policyLogicalName, pNode, roleNode);
          if (newPolicy) {
            removeFirst(nodes, newPolicy);
            newNodesToAdd.push(newPolicy);
            newPolicy["_temp_data_source_definition"] = {
              XTYPE: "aws_iam_policy_document",
              logicalName: docLogicalName,
              statement: optimizedStatements
            };
            newPolicy.cloudResource.params = {
              name: policyLogicalName,
              description: `Access Policy for ${roleLogical}`,
              policy: `data.aws_iam_policy_document.${docLogicalName}.json`
            };
          }
          const newAttach = this.addGenericNode(nodes, "aws_iam_role_policy_attachment", attachmentLogicalName, roleNode, pNode);
          if (newAttach) {
            removeFirst(nodes, newAttach);
            newNodesToAdd.push(newAttach);
            newAttach.cloudResource.params = {
              role: `aws_iam_role.${roleLogical}.name`,
              policy_arn: `aws_iam_policy.${policyLogicalName}.arn`
            };
          }
          didSomething = true;
        }
      }
      if (didSomething)
        allRemovedPolicyIds.add(pNode.key);
    }
    for (const sourceNode of candidates) {
      if (sourceNode["__isGenerated"])
        continue;
      const sourceId = sourceNode.terraformID ?? this.terraformKey;
      const sourceName = sourceNode.logicalName ?? "Unknown";
      const sourceType = sourceNode.type;
      const isResourceBased = sourceType != null && sourceType in resourceBasedMap;
      const groupedData = {};
      const targetsDict = sourceNode.connections?.target ?? {};
      const policyKeys = isResourceBased ? [...targetsDict["aws_iam_policy"] ?? []] : [...targetsDict["aws_iam_policy"] ?? [], ...targetsDict["cldmn_policy"] ?? []];
      for (const pKey of policyKeys) {
        const pNode = this.nodeMap?.[pKey];
        if (!pNode)
          continue;
        const managedPolicyName = pNode.cloudResource?.params?.["managed_policy_"];
        if (managedPolicyName) {
          const attachmentNode = this.addManagedPolicy(sourceNode, managedPolicyName, this.nodeMap);
          flushAttachment(attachmentNode);
        }
        const [stmts] = this.collectPolicyStatements(pNode);
        if (stmts.length > 0) {
          const isMissingActions = stmts.some((s) => !pyTruthy(s["actions"]));
          if (isMissingActions) {
            this.collector.addError(["iam_policy_missing_actions", pNode.key]);
            continue;
          }
        }
        if (stmts.length === 0) {
          if (managedPolicyName) {
            this.bypassVisualConnection(sourceNode, pNode);
            allRemovedPolicyIds.add(pKey);
          }
          continue;
        }
        allRemovedPolicyIds.add(pKey);
        let groupKeyId = "";
        let roleRefForGroup = null;
        let linkNode = null;
        const policyTargets = pNode.connections?.target ?? {};
        let foundLink = false;
        for (const [, targetKeys] of Object.entries(policyTargets)) {
          for (const tKey of targetKeys) {
            const tNode = this.nodeMap?.[tKey];
            if (tNode) {
              linkNode = tNode;
              foundLink = true;
              break;
            }
          }
          if (foundLink)
            break;
        }
        if (linkNode === null)
          linkNode = sourceNode;
        let policyOwner = sourceNode;
        let isRoute3 = false;
        if (isResourceBased) {
          const tId = linkNode.terraformID ?? this.terraformKey;
          const nKey = linkNode.key ?? "unknown_key";
          groupKeyId = `rb_${tId}_${nKey}`;
          roleRefForGroup = null;
        } else {
          roleRefForGroup = this.findRoleReference(sourceNode, this.nodeMap, pNode);
          if (roleRefForGroup) {
            groupKeyId = String(roleRefForGroup);
          } else {
            const linkType = linkNode.type;
            if (linkType != null && linkType in resourceBasedMap) {
              isRoute3 = true;
              policyOwner = linkNode;
              const tId = linkNode.terraformID ?? this.terraformKey;
              const nKey = linkNode.key ?? "unknown_key";
              groupKeyId = `rb_inv_${tId}_${nKey}`;
            } else {
              groupKeyId = "default_no_role_group";
            }
          }
        }
        if (!(groupKeyId in groupedData)) {
          groupedData[groupKeyId] = {
            statements: [],
            link_node: isRoute3 ? sourceNode : linkNode,
            role_ref: roleRefForGroup,
            policy_owner: policyOwner,
            is_resource_based_override: isResourceBased || isRoute3
          };
        }
        groupedData[groupKeyId].statements.push(...stmts);
        this.bypassVisualConnection(sourceNode, pNode);
      }
      const SERVICE_PRINCIPALS = {
        aws_cloudfront_distribution: { principal: "cloudfront.amazonaws.com", condition_type: "ACCOUNT" },
        aws_apigatewayv2_api: { principal: "apigateway.amazonaws.com", condition_type: "ARN" },
        aws_api_gateway_rest_api: { principal: "apigateway.amazonaws.com", condition_type: "ARN" },
        aws_cloudwatch_event_rule: { principal: "events.amazonaws.com", condition_type: "ACCOUNT" },
        aws_sns_topic: { principal: "sns.amazonaws.com", condition_type: "ACCOUNT" },
        aws_sqs_queue: { principal: "sqs.amazonaws.com", condition_type: "ACCOUNT" },
        aws_cloudwatch_log_group: { principal: "logs.amazonaws.com", condition_type: "ACCOUNT" },
        aws_cloudtrail: { principal: "cloudtrail.amazonaws.com", condition_type: "ACCOUNT" },
        aws_cur_report_definition: { principal: "billingreports.amazonaws.com", condition_type: "ACCOUNT" },
        aws_datasync_task: { principal: "datasync.amazonaws.com", condition_type: "ACCOUNT" }
      };
      for (const [, data] of Object.entries(groupedData)) {
        const statements = data.statements;
        const linkNode = data.link_node;
        const roleRef = data.role_ref;
        const policyOwner = data.policy_owner ?? sourceNode;
        const isRbOverride = data.is_resource_based_override ?? isResourceBased;
        if (statements.length === 0)
          continue;
        const optimizedStatements = this.optimizePolicyStatements(statements);
        const currentStateName = this.stateNameMap[sourceId] ?? "UnknownState";
        const ownerName = policyOwner.logicalName ?? "Unknown";
        const ownerType = policyOwner.type;
        if (isRbOverride) {
          const originalSourceType = sourceNode.type ?? "";
          const originalSourceName = sourceNode.logicalName ?? "Unknown";
          const serviceConfig = SERVICE_PRINCIPALS[originalSourceType] ?? {};
          const principalService = serviceConfig.principal;
          const conditionType = serviceConfig.condition_type ?? "ARN";
          for (const stmt of optimizedStatements) {
            if (!("principals" in stmt) || !pyTruthy(stmt["principals"])) {
              if (principalService) {
                stmt["principals"] = [{ type: "Service", identifiers: [principalService] }];
                if (!("condition" in stmt))
                  stmt["condition"] = [];
                let condVar;
                let condVal;
                if (conditionType === "ACCOUNT") {
                  condVar = "AWS:SourceAccount";
                  condVal = "${data.aws_caller_identity.current.account_id}";
                } else {
                  condVar = "AWS:SourceArn";
                  condVal = `\${${originalSourceType}.${originalSourceName}.arn}`;
                }
                const condList = stmt["condition"];
                const hasCondition = condList.some((c) => c["variable"] === condVar);
                if (!hasCondition)
                  condList.push({ test: "StringEquals", variable: condVar, values: [condVal] });
              } else {
                stmt["principals"] = [{ type: "AWS", identifiers: ["*"] }];
              }
            }
          }
          const policyResourceType = resourceBasedMap[ownerType];
          const policyLogicalName = `${policyResourceType}_${ownerName}_st_${currentStateName}`;
          const docLogicalName = `${policyLogicalName}_doc`;
          if (sourceNode.key !== policyOwner.key && conditionType === "ACCOUNT") {
            sourceNode.cloudResource ??= {};
            sourceNode.cloudResource.params ??= {};
            const p = sourceNode.cloudResource.params;
            if (!("depends_on" in p))
              p["depends_on"] = [];
            const fullPolicyRef = `${policyResourceType}.${policyLogicalName}`;
            if (!p["depends_on"].includes(fullPolicyRef))
              p["depends_on"].push(fullPolicyRef);
          }
          const newResPolicy = this.addGenericNode(nodes, policyResourceType, policyLogicalName, policyOwner, linkNode);
          if (newResPolicy) {
            removeFirst(nodes, newResPolicy);
            newNodesToAdd.push(newResPolicy);
            newResPolicy["_temp_data_source_definition"] = {
              XTYPE: "aws_iam_policy_document",
              logicalName: docLogicalName,
              statement: optimizedStatements
            };
            const resParams = newResPolicy.cloudResource.params;
            if (ownerType === "aws_cloudwatch_log_group") {
              resParams["policy_document"] = `data.aws_iam_policy_document.${docLogicalName}.json`;
              resParams["policy_name"] = policyLogicalName;
            } else {
              resParams["policy"] = `data.aws_iam_policy_document.${docLogicalName}.json`;
            }
            if (ownerType === "aws_s3_bucket")
              resParams["bucket"] = `aws_s3_bucket.${ownerName}.id`;
            else if (ownerType === "aws_sqs_queue")
              resParams["queue_url"] = `aws_sqs_queue.${ownerName}.id`;
            else if (ownerType === "aws_kms_key")
              resParams["key_id"] = `aws_kms_key.${ownerName}.id`;
            else if (ownerType === "aws_sns_topic")
              resParams["arn"] = `aws_sns_topic.${ownerName}.arn`;
          }
        } else {
          const cleanType = ownerType.replace("aws_", "").replace("cldmn_", "");
          let suffix = "";
          let roleTypeDesc = "";
          if (roleRef) {
            let rawRoleName = String(roleRef);
            if (rawRoleName.includes("aws_iam_role.")) {
              const parts = rawRoleName.split(".");
              if (parts.length > 1)
                rawRoleName = parts[1];
            }
            if (rawRoleName.includes("_role_")) {
              const leftPart = rawRoleName.split("_role_")[0];
              suffix = `_${leftPart}`;
              roleTypeDesc = leftPart;
            } else if (rawRoleName.toLowerCase().startsWith("role_")) {
              suffix = "";
              roleTypeDesc = "Standard";
            } else {
              suffix = `_${rawRoleName}`;
              roleTypeDesc = rawRoleName;
            }
          }
          const policyLogicalName = `${cleanType}_${sourceName}${suffix}_st_${currentStateName}`;
          const docLogicalName = `${policyLogicalName}_doc`;
          const attachmentLogicalName = `${policyLogicalName}_attach`;
          const newPolicy = this.addGenericNode(nodes, "aws_iam_policy", policyLogicalName, sourceNode, linkNode);
          if (newPolicy) {
            removeFirst(nodes, newPolicy);
            newNodesToAdd.push(newPolicy);
            newPolicy["_temp_data_source_definition"] = {
              XTYPE: "aws_iam_policy_document",
              logicalName: docLogicalName,
              statement: optimizedStatements
            };
            let descText = `Access Policy for ${sourceName}`;
            if (suffix)
              descText += ` (Role: ${roleTypeDesc})`;
            newPolicy.cloudResource.params = {
              name: policyLogicalName,
              description: descText,
              policy: `data.aws_iam_policy_document.${docLogicalName}.json`
            };
          }
          if (roleRef) {
            const newAttach = this.addGenericNode(
              nodes,
              "aws_iam_role_policy_attachment",
              attachmentLogicalName,
              linkNode ? linkNode : sourceNode,
              sourceNode
            );
            if (newAttach) {
              removeFirst(nodes, newAttach);
              newNodesToAdd.push(newAttach);
              let roleValue = roleRef;
              if (!String(roleRef).includes("aws_iam_role"))
                roleValue = `aws_iam_role.${roleRef}.name`;
              newAttach.cloudResource.params = { role: roleValue, policy_arn: `aws_iam_policy.${policyLogicalName}.arn` };
            }
          }
        }
      }
    }
    const finalNodes = nodes.filter((n) => !allRemovedPolicyIds.has(n.key));
    finalNodes.push(...newNodesToAdd);
    const tempNodeMap = {};
    for (const node of finalNodes)
      if (node.key != null)
        tempNodeMap[node.key] = node;
    const roleToAttachments = {};
    for (const n of finalNodes) {
      if (n.type === "aws_iam_role_policy_attachment") {
        const params = n.cloudResource?.params ?? {};
        const roleRef = params["role"];
        if (!roleRef)
          continue;
        const roleLn = roleRef.includes("aws_iam_role.") ? roleRef.split(".")[1] : roleRef;
        const attachLn = n.logicalName;
        if (attachLn)
          (roleToAttachments[roleLn] ??= []).push(attachLn);
      }
    }
    const containsRoleReference = /* @__PURE__ */ __name((data, roleName) => {
      if (typeof data === "string") {
        const targetRef = `aws_iam_role.${roleName}`;
        return data.includes(targetRef) || roleName === data;
      } else if (isPlainObject2(data)) {
        return Object.values(data).some((v) => containsRoleReference(v, roleName));
      } else if (Array.isArray(data)) {
        return data.some((item) => containsRoleReference(item, roleName));
      }
      return false;
    }, "containsRoleReference");
    for (const n of finalNodes) {
      const nType = n.type ?? "";
      if (nType === "aws_iam_role" || nType === "aws_iam_role_policy_attachment" || nType === "aws_iam_policy")
        continue;
      const conns = n.connections ?? {};
      const referencedRoles = /* @__PURE__ */ new Set();
      const roleKeys = conns.source?.["aws_iam_role"] ?? [];
      for (const rKey of roleKeys) {
        const rNode = tempNodeMap[rKey];
        if (rNode) {
          const roleLn = rNode.logicalName;
          if (roleLn) {
            const params = n.cloudResource?.params ?? {};
            if (containsRoleReference(params, roleLn))
              referencedRoles.add(roleLn);
          }
        }
      }
      if (referencedRoles.size > 0) {
        for (const rLn of referencedRoles) {
          const attachments = roleToAttachments[rLn] ?? [];
          for (const attachLn of attachments) {
            n.cloudResource ??= {};
            n.cloudResource.params ??= {};
            const p = n.cloudResource.params;
            if (!("depends_on" in p))
              p["depends_on"] = [];
            const fullAttachmentRef = `aws_iam_role_policy_attachment.${attachLn}`;
            if (!p["depends_on"].includes(fullAttachmentRef))
              p["depends_on"].push(fullAttachmentRef);
          }
        }
      }
    }
    this.payload.nodes = finalNodes;
    return this.payload;
  }
  // Port de _find_upstream_security_group (core/10_shared.py). Recursivo, puro:
  // acha um SG conectado à 'source' do nó (direto ou subindo a árvore).
  findUpstreamSecurityGroup(startNode, nodeMap, visited = /* @__PURE__ */ new Set()) {
    if (visited.has(startNode.key))
      return null;
    visited.add(startNode.key);
    if (startNode.type === "aws_security_group")
      return startNode;
    const connections = startNode.connections?.source ?? {};
    const sgList = connections["aws_security_group"] ?? [];
    if (sgList.length > 0)
      return nodeMap[sgList[0]] ?? null;
    for (const [srcType, srcKeys] of Object.entries(connections)) {
      if (srcType.startsWith("cldmn_") || srcType === "aws_security_group")
        continue;
      for (const key of srcKeys) {
        const parent = nodeMap[key];
        if (parent) {
          const found = this.findUpstreamSecurityGroup(parent, nodeMap, visited);
          if (found)
            return found;
        }
      }
    }
    return null;
  }
  // Port de _find_attached_security_group (core/10_shared.py). Recursivo, puro:
  // acha o SG de destino (quem recebe o tráfego), com filtros de navegação
  // (não entra em VPC nem volta pro balanceador aws_lb*).
  findAttachedSecurityGroup(targetNode, nodeMap, visited = /* @__PURE__ */ new Set()) {
    if (visited.has(targetNode.key))
      return null;
    visited.add(targetNode.key);
    if (targetNode.type === "aws_security_group")
      return targetNode;
    const connections = targetNode.connections ?? {};
    const sourceConns = connections.source ?? {};
    const sgList = sourceConns["aws_security_group"] ?? [];
    if (sgList.length > 0)
      return nodeMap[sgList[0]] ?? null;
    const targetConns = connections.target ?? {};
    const allNeighbors = [];
    for (const [cType, keys] of Object.entries(targetConns))
      allNeighbors.push([cType, keys]);
    for (const [cType, keys] of Object.entries(sourceConns))
      allNeighbors.push([cType, keys]);
    for (const [neighborType, neighborKeys] of allNeighbors) {
      if (neighborType === "aws_security_group")
        continue;
      if (neighborType === "aws_vpc")
        continue;
      if (neighborType.startsWith("aws_lb"))
        continue;
      for (const key of neighborKeys) {
        const parent = nodeMap[key];
        if (parent) {
          const found = this.findAttachedSecurityGroup(parent, nodeMap, visited);
          if (found)
            return found;
        }
      }
    }
    return null;
  }
  // Port de _disambiguate_sg_names (core/10_shared.py). Prefixa o nome lógico de
  // cada SG com o tipo do recurso pai (sem "aws_") pra evitar colisões. Usa
  // this.nodes/this.nodeMap. Idempotente. Muta node.logicalName.
  disambiguateSgNames() {
    for (const node of this.nodes) {
      if (node.type !== "aws_security_group")
        continue;
      const currentLogicalName = node.logicalName;
      if (!currentLogicalName)
        continue;
      const sourceConnections = node.connections?.source ?? {};
      let sourceNode = null;
      for (const [srcType, srcKeys] of Object.entries(sourceConnections)) {
        if (srcType === "cldmn_sg_rule")
          continue;
        if (srcKeys.length > 0) {
          sourceNode = this.nodeMap?.[srcKeys[0]] ?? null;
          if (sourceNode)
            break;
        }
      }
      if (sourceNode) {
        const srcRawType = sourceNode.type ?? "";
        const prefix = srcRawType.includes("_") ? srcRawType.slice(srcRawType.indexOf("_") + 1) : srcRawType;
        const prefixStr = `${prefix}_`;
        if (!currentLogicalName.startsWith(prefixStr)) {
          node.logicalName = `${prefixStr}${currentLogicalName}`;
        }
      }
    }
  }
  // Port de _create_ingress_rule_resource (core/10_shared.py). Cria um
  // aws_security_group_rule (ingress) a partir de um cldmn_sg_rule, ligando
  // source_sg -> target_sg. Dedupe por nome lógico na lista sendo gerada.
  createIngressRuleResource(ruleNode, sourceSg, targetSg, generatedList) {
    const ruleParams = ruleNode.cloudResource?.params ?? {};
    const ruleDefinitionList = ruleParams["ingress"] ?? [];
    const ruleContent = Array.isArray(ruleDefinitionList) && ruleDefinitionList.length > 0 ? ruleDefinitionList[0] : {};
    const fromPort = ruleContent["from_port"] ?? 0;
    const toPort = ruleContent["to_port"] ?? 0;
    const protocol = ruleContent["protocol"] ?? "-1";
    let descText = ruleContent["description"];
    if (!descText)
      descText = `Allow from ${sourceSg.logicalName} (${protocol}:${fromPort}-${toPort})`;
    let portSuffix;
    if (String(protocol) === "-1")
      portSuffix = "all_protocols";
    else if (fromPort === toPort)
      portSuffix = `${protocol}_${fromPort}`;
    else
      portSuffix = `${protocol}_${fromPort}_${toPort}`;
    const sourceName = sourceSg.logicalName;
    const targetName = targetSg.logicalName;
    let ruleLogicalName = `rule_${sourceName}_to_${targetName}_${portSuffix}`;
    ruleLogicalName = ruleLogicalName.replaceAll("-", "_").replaceAll(" ", "");
    for (const gn of generatedList) {
      if (gn.logicalName === ruleLogicalName)
        return;
    }
    const sourceRefId = `aws_security_group.${sourceSg.logicalName}.id`;
    const newRuleNode = this.addGenericNode(generatedList, "aws_security_group_rule", ruleLogicalName, sourceSg, targetSg);
    if (newRuleNode) {
      const resParams = newRuleNode.cloudResource.params;
      resParams["type"] = "ingress";
      resParams["from_port"] = fromPort;
      resParams["to_port"] = toPort;
      resParams["protocol"] = protocol;
      resParams["description"] = descText;
      resParams["security_group_id"] = `aws_security_group.${targetSg.logicalName}.id`;
      resParams["source_security_group_id"] = sourceRefId;
    }
  }
  // Port de preprocess_security_groups (core/10_shared.py). ORQUESTRADOR de SG:
  // (1) converte regras inline ingress/egress dos SGs em aws_security_group_rule
  // standalone; (2) resolve cldmn_sg_rule (origem/destino via find_upstream/
  // find_attached), decide o estado dono pelo ranking e cria a regra de ingress.
  // Usa/muta this.nodes/nodeMap/domainNodeKeys/stateRankMap. Retorna this.payload.
  preprocessSecurityGroups() {
    const nodes = this.payload.nodes ?? [];
    this.nodes = nodes;
    const executionOrder = this.payload.executionOrder ?? [];
    this.stateRankMap = {};
    executionOrder.forEach((tfId, i) => {
      this.stateRankMap[tfId] = i;
    });
    const currentStateRank = this.stateRankMap[this.terraformKey] ?? -1;
    const generatedRules = [];
    const ruleKeysToRemove = /* @__PURE__ */ new Set();
    const inlineRulesList = [];
    for (const node of nodes) {
      if (node.type !== "aws_security_group" || !this.domainNodeKeys.includes(node.key))
        continue;
      const logicalName = node.logicalName ?? "unknown";
      const params = node.cloudResource?.params ?? {};
      for (const ruleType of ["ingress", "egress"]) {
        const rulesData = params[ruleType];
        if (Array.isArray(rulesData) && rulesData.length > 0) {
          for (const ruleItem of rulesData) {
            const protocol = ruleItem["protocol"] ?? "-1";
            const fromPort = ruleItem["from_port"] ?? 0;
            const toPort = ruleItem["to_port"] ?? 0;
            let portSuffix;
            if (String(protocol) === "-1")
              portSuffix = "all_protocols";
            else if (fromPort === toPort)
              portSuffix = `${protocol}_${fromPort}`;
            else
              portSuffix = `${protocol}_${fromPort}_${toPort}`;
            let ruleLogName = `rule_${logicalName}_${ruleType}_${portSuffix}`;
            ruleLogName = ruleLogName.replaceAll("-", "_").replaceAll(" ", "");
            const newNode = this.addGenericNode(inlineRulesList, "aws_security_group_rule", ruleLogName, node, node);
            if (newNode) {
              const newParams = {
                type: ruleType,
                security_group_id: `aws_security_group.${logicalName}.id`,
                from_port: ruleItem["from_port"],
                to_port: ruleItem["to_port"],
                protocol: ruleItem["protocol"],
                description: ruleItem["description"] ?? ""
              };
              if ("cidr_blocks" in ruleItem)
                newParams["cidr_blocks"] = ruleItem["cidr_blocks"];
              if ("ipv6_cidr_blocks" in ruleItem)
                newParams["ipv6_cidr_blocks"] = ruleItem["ipv6_cidr_blocks"];
              if ("prefix_list_ids" in ruleItem)
                newParams["prefix_list_ids"] = ruleItem["prefix_list_ids"];
              if (ruleItem["self"])
                newParams["self"] = true;
              if (ruleItem["security_groups"]) {
                const secGroups = ruleItem["security_groups"];
                if (Array.isArray(secGroups) && secGroups.length > 0)
                  newParams["source_security_group_id"] = secGroups[0];
                else
                  newParams["source_security_group_id"] = secGroups;
              }
              newNode.cloudResource.params = newParams;
              newNode["pushCode"] = true;
            }
          }
          delete params[ruleType];
        }
      }
    }
    nodes.push(...inlineRulesList);
    const EXCLUDED = /* @__PURE__ */ new Set(["aws_subnet", "aws_vpc", "aws_az_", "cldmn_box"]);
    for (const node of nodes) {
      if (node.type !== "cldmn_sg_rule")
        continue;
      const sourceConnections = node.connections?.source ?? {};
      const targetConnections = node.connections?.target ?? {};
      const sourceKeys = [];
      for (const [connType, keys] of Object.entries(sourceConnections))
        if (!EXCLUDED.has(connType))
          sourceKeys.push(...keys);
      const targetKeys = [];
      for (const [connType, keys] of Object.entries(targetConnections))
        if (!EXCLUDED.has(connType))
          targetKeys.push(...keys);
      if (sourceKeys.length === 0 || targetKeys.length === 0)
        continue;
      for (const srcKey of sourceKeys) {
        const sourceNode = this.nodeMap?.[srcKey];
        if (!sourceNode)
          continue;
        let sourceSg = this.findUpstreamSecurityGroup(sourceNode, this.nodeMap);
        if (!sourceSg) {
          if (sourceNode.type === "aws_security_group")
            sourceSg = sourceNode;
          else
            continue;
        }
        for (const tgtKey of targetKeys) {
          const targetNode = this.nodeMap?.[tgtKey];
          if (!targetNode)
            continue;
          let targetSg = this.findAttachedSecurityGroup(targetNode, this.nodeMap);
          if (!targetSg) {
            if (targetNode.type === "aws_security_group")
              targetSg = targetNode;
            else
              continue;
          }
          if (sourceSg.key === targetSg.key)
            continue;
          const srcRank = this.stateRankMap[sourceSg.terraformID] ?? -1;
          const tgtRank = this.stateRankMap[targetSg.terraformID] ?? -1;
          const targetRankForRule = Math.max(srcRank, tgtRank);
          if (targetRankForRule === currentStateRank) {
            this.createIngressRuleResource(node, sourceSg, targetSg, generatedRules);
            ruleKeysToRemove.add(node.key);
          }
        }
      }
    }
    this.payload.nodes = nodes.filter((n) => !ruleKeysToRemove.has(n.key));
    this.payload.nodes.push(...generatedRules);
    for (const rule of generatedRules) {
      if (this.nodeMap)
        this.nodeMap[rule.key] = rule;
      if (!this.domainNodeKeys.includes(rule.key))
        this.domainNodeKeys.push(rule.key);
    }
    return this.payload;
  }
  // ==========================================================================
  // CASCA DO PIPELINE: dispatch (pre_process/process) + enrich + header
  // ==========================================================================
  // Port de _preprocess_generic_links (core/10_shared.py). Realoca o terraformID
  // de nós "Link" pro estado de maior rank entre os conectados, e remove da fila
  // os que não pertencem ao estado ativo. Muta this.nodes/domainNodeKeys.
  preprocessGenericLinks(allNodes, rankMap) {
    const nodesToRemove = [];
    for (const n of allNodes) {
      if ((n["typeList"] ?? []).includes("Link")) {
        const connectedNodeIds = [];
        const connections = n.connections ?? {};
        for (const direction of ["source", "target"]) {
          const dirConns = connections[direction] ?? {};
          for (const keys of Object.values(dirConns))
            connectedNodeIds.push(...keys);
        }
        let highestRank = -1;
        let bestStateId = null;
        for (const nodeId of connectedNodeIds) {
          const connectedNode = this.nodeMap?.[nodeId];
          const stateId = connectedNode?.terraformID;
          if (stateId) {
            const rank = rankMap[stateId] ?? -1;
            if (rank > highestRank) {
              highestRank = rank;
              bestStateId = stateId;
            }
          }
        }
        if (bestStateId) {
          const nKey = n.key;
          n.terraformID = bestStateId;
          if (bestStateId === this.terraformKey) {
            if (nKey && !this.domainNodeKeys.includes(nKey))
              this.domainNodeKeys.push(nKey);
          } else {
            if (nKey && this.domainNodeKeys.includes(nKey))
              removeFirst(this.domainNodeKeys, nKey);
            nodesToRemove.push(n);
          }
        }
      }
    }
    for (const nRem of nodesToRemove)
      removeFirst(this.nodes, nRem);
  }
  // Port de pre_process_nodes (core/10_shared.py). Dispatch handle_pre_{tipo}
  // (prioriza subnet/vpc). Handlers leem this.node. Muta payload.nodes.
  preProcessNodes() {
    this.stateRankMap = createStateRankMap(this.payload);
    const nodes = this.payload.nodes ?? [];
    this.nodes = nodes;
    this.generatedNodes = [];
    this.preprocessGenericLinks(nodes, this.stateRankMap);
    const PRIORITY_TYPES = /* @__PURE__ */ new Set(["aws_subnet", "aws_vpc"]);
    const priorityNodes = nodes.filter((n) => n.type != null && PRIORITY_TYPES.has(n.type));
    const otherNodes = nodes.filter((n) => !(n.type != null && PRIORITY_TYPES.has(n.type)));
    const orderedNodes = [...priorityNodes, ...otherNodes];
    const processedKeys = /* @__PURE__ */ new Set();
    for (const node of orderedNodes) {
      const nodeType = node.type;
      if (!nodeType || processedKeys.has(node.key))
        continue;
      processedKeys.add(node.key);
      this.node = node;
      const handler = this[`handle_pre_${nodeType}`];
      if (typeof handler === "function") {
        try {
          handler.call(this);
        } catch {
        }
      }
    }
    if (this.generatedNodes.length > 0)
      this.payload.nodes.push(...this.generatedNodes);
    return this.payload;
  }
  // Port de process_nodes (core/10_shared.py). Dispatch handle_{tipo} + síntese
  // de recursos random ausentes no fim. Handlers leem this.node.
  processNodes() {
    this.stateRankMap = createStateRankMap(this.payload);
    const nodes = this.payload.nodes ?? [];
    this.nodes = nodes;
    this.generatedNodes = [];
    this.stateNameMap = {};
    for (const n of nodes) {
      if (n.type === "cldmn_terraform")
        this.stateNameMap[n.key] = n.logicalName ?? "UnknownState";
    }
    const processedKeys = /* @__PURE__ */ new Set();
    for (const node of [...nodes]) {
      const nodeKey = node.key;
      if (processedKeys.has(nodeKey) || !node.type)
        continue;
      processedKeys.add(nodeKey);
      this.node = node;
      const handler = this[`handle_${node.type}`];
      if (typeof handler === "function") {
        try {
          handler.call(this);
        } catch {
        }
      }
    }
    this.synthesizeMissingRandomResources();
    if (this.generatedNodes.length > 0)
      this.payload.nodes.push(...this.generatedNodes);
    return this.payload;
  }
  // Port de _synthesize_missing_random_resources (core/10_shared.py). Sintetiza
  // random_password/random_id referenciados mas nunca declarados (comum em import).
  synthesizeMissingRandomResources() {
    const RANDOM_TYPE_DEFAULTS = {
      random_password: { length: 16, special: true },
      random_id: { byte_length: 8 }
    };
    const pattern = /^(random_password|random_id)\.([a-zA-Z0-9_-]+)\.[a-zA-Z0-9_]+$/;
    const existing = /* @__PURE__ */ new Set();
    for (const n of this.nodes)
      if (n.type && n.type in RANDOM_TYPE_DEFAULTS)
        existing.add(`${n.type}::${n.logicalName}`);
    for (const n of this.generatedNodes)
      if (n.type && n.type in RANDOM_TYPE_DEFAULTS)
        existing.add(`${n.type}::${n.logicalName}`);
    const foundSet = /* @__PURE__ */ new Set();
    const foundArr = [];
    const scan = /* @__PURE__ */ __name((value) => {
      if (typeof value === "string") {
        const m = value.trim().match(pattern);
        if (m) {
          const k = `${m[1]}::${m[2]}`;
          if (!foundSet.has(k)) {
            foundSet.add(k);
            foundArr.push([m[1], m[2]]);
          }
        }
      } else if (Array.isArray(value))
        for (const v of value)
          scan(v);
      else if (isPlainObject2(value))
        for (const v of Object.values(value))
          scan(v);
    }, "scan");
    for (const n of this.nodes)
      scan(n.cloudResource?.params ?? {});
    const domainKeys = this.payload.domainNodeKeys ?? [];
    for (const [resType, resName] of foundArr) {
      if (existing.has(`${resType}::${resName}`))
        continue;
      const defaults = RANDOM_TYPE_DEFAULTS[resType];
      const newKey = `synth_${resType}_${resName}`;
      const newNode = {
        key: newKey,
        type: resType,
        logicalName: resName,
        cloudResource: { uiState: {}, params: { ...defaults } },
        __isImplicit: true
      };
      this.generatedNodes.push(newNode);
      if (!domainKeys.includes(newKey))
        domainKeys.push(newKey);
    }
    this.payload.domainNodeKeys = domainKeys;
  }
  // Port de add_tag_cloudman_permission (core/10_shared.py). Marca aws_ssm_parameter
  // vindo de cldmn_pipeline com a tag Struct8:Managed=allow.
  addTagCloudmanPermission(payload, nodeMap) {
    const validNodes = payload.nodes ?? [];
    for (const node of validNodes) {
      if (node.type === "aws_ssm_parameter") {
        const sources = node.connections?.source ?? {};
        const allSourceKeys = [];
        for (const keyList of Object.values(sources))
          allSourceKeys.push(...keyList);
        let hasPipelineSource = false;
        for (const srcKey of allSourceKeys) {
          const srcNode = nodeMap[srcKey];
          if (srcNode && srcNode.type === "cldmn_pipeline") {
            hasPipelineSource = true;
            break;
          }
        }
        if (hasPipelineSource) {
          const params = node.cloudResource?.params ?? {};
          if (!("tags" in params))
            params["tags"] = {};
          if (isPlainObject2(params["tags"]))
            params["tags"]["Struct8:Managed"] = "allow";
        }
      }
    }
    return payload;
  }
  // Port de enrich_aws_tags_and_remove_nodes (core/10_shared.py). Remove nós com
  // pushCode===false, injeta tags padrão (Name/State/Struct8User), aplica tags
  // dinâmicas de cldmn_tag, remove tags de recursos sem suporte, e faz o swap
  // DifName<->Name. Muta payload.nodes.
  enrichAwsTagsAndRemoveNodes() {
    const originalNodes = this.payload.nodes ?? [];
    if (originalNodes.length === 0)
      return this.payload;
    const validNodes = originalNodes.filter((node) => (node["pushCode"] ?? true) !== false);
    this.payload.nodes = validNodes;
    const stateValue = this.payload.terraformNodeName ?? "Unknown";
    const userNameValue = this.payload.userName ?? "Unknown";
    for (const node of validNodes) {
      const params = node.cloudResource?.params ?? {};
      const logicalName = node.logicalName ?? "";
      if (node.type === "aws_autoscaling_group") {
        if (!("tag" in params))
          params["tag"] = [];
        if (Array.isArray(params["tag"])) {
          params["tag"].push(
            { key: "Name", value: logicalName, propagate_at_launch: true },
            { key: "State", value: stateValue, propagate_at_launch: true },
            { key: "Struct8User", value: userNameValue, propagate_at_launch: true }
          );
        }
      } else if ("tags" in params && isPlainObject2(params["tags"])) {
        const tags = params["tags"];
        tags["Name"] = logicalName;
        tags["State"] = stateValue;
        tags["Struct8User"] = userNameValue;
      }
    }
    this.addTagCloudmanPermission(this.payload, this.nodeMap);
    const tagComponents = validNodes.filter((n) => n.type === "cldmn_tag");
    for (const tagNode of tagComponents) {
      const dynamicTagsList = tagNode.cloudResource?.params?.["tags"];
      if (!Array.isArray(dynamicTagsList))
        continue;
      const dynamicTagsDict = {};
      for (const tag of dynamicTagsList) {
        if (isPlainObject2(tag) && "key" in tag && "value" in tag)
          dynamicTagsDict[tag["key"]] = tag["value"];
      }
      if (Object.keys(dynamicTagsDict).length === 0)
        continue;
      let targetNodes = [];
      const explicitTargets = tagNode.connections?.target ?? {};
      if (Object.keys(explicitTargets).length > 0) {
        const allTargetKeys = [];
        for (const keyList of Object.values(explicitTargets))
          allTargetKeys.push(...keyList);
        targetNodes = allTargetKeys.filter((k) => this.nodeMap && k in this.nodeMap).map((k) => this.nodeMap[k]);
      } else {
        const parentKey = tagNode["group"];
        if (parentKey)
          targetNodes = getNodesInGroup(parentKey, validNodes);
      }
      for (const targetNode of targetNodes) {
        if (targetNode.type === "cldmn_tag")
          continue;
        const params = targetNode.cloudResource?.params ?? {};
        if (targetNode.type === "aws_autoscaling_group") {
          if (!("tag" in params))
            params["tag"] = [];
          if (Array.isArray(params["tag"])) {
            for (const [k, v] of Object.entries(dynamicTagsDict))
              params["tag"].push({ key: k, value: v, propagate_at_launch: true });
          }
        } else if ("tags" in params && isPlainObject2(params["tags"])) {
          Object.assign(params["tags"], dynamicTagsDict);
        }
      }
    }
    const resourcesWithoutTags = /* @__PURE__ */ new Set([
      "aws_route",
      "aws_route_table_association",
      "aws_iam_role_policy_attachment",
      "aws_iam_user_policy_attachment",
      "aws_iam_group_policy_attachment",
      "aws_iam_policy_attachment",
      "aws_security_group_rule",
      "aws_network_interface_attachment",
      "aws_vpn_gateway_attachment",
      "aws_db_subnet_group_association",
      "aws_vpc_ipv4_cidr_block_association",
      "aws_lambda_permission",
      "aws_route53_record",
      "aws_acm_certificate_validation",
      "aws_s3_bucket_policy",
      "aws_lb_target_group_attachment",
      "aws_efs_mount_target",
      "aws_sqs_queue_policy",
      "aws_sns_topic_policy",
      "aws_network_acl_rule",
      "aws_ce_cost_allocation_tag",
      "aws_cloudwatch_log_resource_policy"
    ]);
    for (const node of validNodes) {
      if (node.type != null && resourcesWithoutTags.has(node.type)) {
        const params = node.cloudResource?.params;
        if (params)
          delete params["tags"];
      }
    }
    for (const node of validNodes) {
      const params = node.cloudResource?.params ?? {};
      if ("tags" in params && isPlainObject2(params["tags"])) {
        const tagsDict = params["tags"];
        if ("DifName" in tagsDict && "Name" in tagsDict) {
          const tmp = tagsDict["Name"];
          tagsDict["Name"] = tagsDict["DifName"];
          tagsDict["DifName"] = tmp;
        }
      } else if (node.type === "aws_autoscaling_group" && "tag" in params && Array.isArray(params["tag"])) {
        const asgTags = params["tag"];
        let difIdx = null;
        let nameIdx = null;
        asgTags.forEach((t, i) => {
          if (t["key"] === "DifName")
            difIdx = i;
          else if (t["key"] === "Name")
            nameIdx = i;
        });
        if (difIdx !== null && nameIdx !== null) {
          const tmp = asgTags[nameIdx]["value"];
          asgTags[nameIdx]["value"] = asgTags[difIdx]["value"];
          asgTags[difIdx]["value"] = tmp;
        }
      }
    }
    return this.payload;
  }
  // Port de generate_header (core/10_shared.py). Bloco terraform{} + providers +
  // backend s3 (se configurado) + provider aws + data sources padrão + providers
  // dinâmicos.
  generateHeader(region, accountId, backendConfig = {}, providerAssumeRoleArn = null) {
    const headerLines = [];
    headerLines.push("terraform {");
    headerLines.push('  required_version = ">= 1.0.0"');
    headerLines.push("\n  required_providers {");
    for (const providerName of [...this.activeProviders].sort()) {
      const config2 = this.providerDefinitions[providerName] ?? { source: `hashicorp/${providerName}`, version: "latest" };
      headerLines.push(`    ${providerName} = {`);
      headerLines.push(`      source  = "${config2.source}"`);
      headerLines.push(`      version = "${config2.version}"`);
      headerLines.push("    }");
    }
    headerLines.push("  }");
    if (backendConfig && "bucket" in backendConfig && "key" in backendConfig) {
      headerLines.push('\n  backend "s3" {');
      headerLines.push(`    bucket         = "${backendConfig["bucket"]}"`);
      headerLines.push(`    key            = "${backendConfig["key"]}"`);
      headerLines.push(`    region         = "${backendConfig["region"] ?? "us-east-1"}"`);
      const dynamoTable = backendConfig["dynamodb_table"];
      if (dynamoTable)
        headerLines.push(`    dynamodb_table = "${dynamoTable}"`);
      headerLines.push("    encrypt        = true");
      headerLines.push("  }");
    }
    headerLines.push("}");
    headerLines.push("\n# --- Main Cloud Provider ---");
    headerLines.push('provider "aws" {');
    headerLines.push(`  region = "${region}"`);
    if (providerAssumeRoleArn) {
      headerLines.push("  assume_role {");
      headerLines.push(`    role_arn = "${providerAssumeRoleArn}"`);
      headerLines.push("  }");
    }
    headerLines.push("}");
    headerLines.push('\ndata "aws_caller_identity" "current" {}');
    headerLines.push('data "aws_region" "current" {}');
    if (Object.keys(this.dynamicProviderConfigs).length > 0) {
      headerLines.push("\n# --- Extra Providers ---");
      for (const [pName, pConfig] of Object.entries(this.dynamicProviderConfigs)) {
        headerLines.push(`provider "${pName}" {`);
        const lines = this.hcl.renderParamsRecursive(pConfig, "  ");
        headerLines.push(...lines);
        headerLines.push("}");
      }
    }
    return headerLines.join("\n");
  }
};
__name(AwsProviderLogic, "AwsProviderLogic");

// src/datasourceStrategies.ts
var DATASOURCE_STRATEGIES = {
  // --- STORAGE ---
  aws_efs_file_system: { type: "direct" },
  aws_efs_access_point: { type: "direct" },
  aws_s3_bucket: { type: "direct", attr: "bucket", source_param: "name" },
  // --- IAM & SECURITY ---
  aws_cognito_user_pool: {
    type: "direct",
    attr: "user_pool_id",
    source_param: "name",
    attribute_mapping: {
      id: { target_type: "aws_cognito_user_pools", suffix: ".ids[0]" }
    }
  },
  // --- COMPUTE ---
  aws_instance: {
    type: "filter",
    tag_key: "Name",
    extra_filters: [{ name: "instance-state-name", values: ["running"] }]
  },
  aws_ami: { type: "filter", tag_key: "Name" },
  aws_autoscaling_group: { type: "direct", attr: "name", source_param: "name" },
  // --- NETWORKING ---
  aws_vpc: { type: "filter", tag_key: "Name" },
  aws_subnet: { type: "filter", tag_key: "Name" },
  aws_security_group: { type: "filter", tag_key: "Name" },
  aws_internet_gateway: { type: "filter", tag_key: "Name" },
  aws_nat_gateway: { type: "filter", tag_key: "Name" },
  aws_route_table: { type: "filter", tag_key: "Name" },
  aws_vpc_endpoint: { type: "filter", tag_key: "Name" },
  aws_vpc_peering_connection: { type: "filter", tag_key: "Name" },
  aws_eip: { type: "filter", tag_key: "Name" },
  // --- DATABASE ---
  aws_db_instance: { type: "direct", attr: "db_instance_identifier", source_param: "name" },
  aws_rds_cluster: { type: "direct", attr: "cluster_identifier", source_param: "name" },
  // --- SERVERLESS & APP INTEGRATION ---
  aws_apigatewayv2_api: { type: "filter", tag_key: "Name" },
  aws_msk_cluster: { type: "filter", tag_key: "Name" },
  // --- LOAD BALANCING & DNS ---
  aws_lb_target_group: { type: "direct", attr: "name", source_param: "name" },
  aws_lb: { type: "direct", attr: "name", source_param: "name" },
  // --- SECURITY ---
  aws_secretsmanager_secret_version: { type: "direct", attr: "secret_id", source_param: "name" },
  aws_acm_certificate: { type: "direct", attr: "domain", source_param: "domain_name" }
};
function deleteAllKeys(obj) {
  for (const k of Object.keys(obj))
    delete obj[k];
}
__name(deleteAllKeys, "deleteAllKeys");
var handlerAwsSecretsmanagerSecretVersion = /* @__PURE__ */ __name((params, node, implicitList, existingDataSources, nodeMap) => {
  let sourceLogicalName = null;
  if (nodeMap && Object.keys(nodeMap).length > 0) {
    const connections = node.connections?.source ?? {};
    const parentIds = connections["aws_secretsmanager_secret"] ?? [];
    if (parentIds.length > 0) {
      const parentNode = nodeMap[parentIds[0]];
      if (parentNode)
        sourceLogicalName = parentNode.logicalName ?? null;
    }
  }
  if (!sourceLogicalName) {
    const val = params["secret_id"];
    if (val && typeof val === "string" && !["data.", "aws_", "${", "var.", "module."].some((p) => val.startsWith(p))) {
      sourceLogicalName = val;
    }
  }
  if (sourceLogicalName) {
    params["secret_id"] = `aws_secretsmanager_secret.${sourceLogicalName}.id`;
    const inImplicit = implicitList != null && implicitList.some((item) => item.type === "aws_secretsmanager_secret" && item.name === sourceLogicalName);
    const inExternal = sourceLogicalName in existingDataSources;
    if (!inImplicit && !inExternal && implicitList != null) {
      const blockText = `data "aws_secretsmanager_secret" "${sourceLogicalName}" {
  name = "${sourceLogicalName}"
}`;
      implicitList.push({ type: "aws_secretsmanager_secret", name: sourceLogicalName, text: blockText });
    }
  }
  return params;
}, "handlerAwsSecretsmanagerSecretVersion");
var handlerAwsAcmCertificate = /* @__PURE__ */ __name((params) => {
  if (!("statuses" in params))
    params["statuses"] = ["ISSUED"];
  if (!("most_recent" in params))
    params["most_recent"] = true;
  return params;
}, "handlerAwsAcmCertificate");
var handlerAwsCognitoUserPool = /* @__PURE__ */ __name((params, node, implicitList) => {
  const logicalName = node.logicalName;
  const searchDsType = "aws_cognito_user_pools";
  const searchDsName = logicalName;
  if (implicitList != null) {
    const alreadyExists = implicitList.some((i) => i.type === searchDsType && i.name === searchDsName);
    if (!alreadyExists) {
      const poolName = "name" in params ? params["name"] : logicalName;
      const implicitBlock = `data "${searchDsType}" "${searchDsName}" {
  name = "${poolName}"
}`;
      implicitList.push({ type: searchDsType, name: searchDsName, text: implicitBlock });
    }
  }
  params["user_pool_id"] = `data.${searchDsType}.${searchDsName}.ids[0]`;
  if ("name" in params)
    delete params["name"];
  return params;
}, "handlerAwsCognitoUserPool");
var handlerAwsEfsFileSystem = /* @__PURE__ */ __name((params, node) => {
  const logicalName = node.logicalName;
  const tagValue = "name" in params ? params["name"] : logicalName;
  deleteAllKeys(params);
  params["tags"] = { Name: tagValue };
  return params;
}, "handlerAwsEfsFileSystem");
var handlerAwsEfsAccessPoint = /* @__PURE__ */ __name((params, node, implicitList, _existingDataSources, nodeMap) => {
  const logicalName = node.logicalName;
  let efsLogicalName = "EFS";
  if (nodeMap && Object.keys(nodeMap).length > 0) {
    const connections = node.connections?.source ?? {};
    const efsIds = connections["aws_efs_file_system"] ?? [];
    if (efsIds.length > 0) {
      const efsNode = nodeMap[efsIds[0]];
      if (efsNode)
        efsLogicalName = efsNode.logicalName ?? efsLogicalName;
    }
  }
  if (implicitList != null) {
    const searchDs = "aws_efs_access_points";
    const alreadyExists = implicitList.some((i) => i.name === logicalName && i.type === searchDs);
    if (!alreadyExists) {
      const implicitBlock = `data "${searchDs}" "${logicalName}" {
  file_system_id = data.aws_efs_file_system.${efsLogicalName}.id
}`;
      implicitList.push({ type: searchDs, name: logicalName, text: implicitBlock });
    }
  }
  deleteAllKeys(params);
  params["access_point_id"] = `__RAW__tolist(data.aws_efs_access_points.${logicalName}.ids)[0]`;
  return params;
}, "handlerAwsEfsAccessPoint");
var DATASOURCE_HANDLERS = {
  aws_secretsmanager_secret_version: handlerAwsSecretsmanagerSecretVersion,
  aws_acm_certificate: handlerAwsAcmCertificate,
  aws_cognito_user_pool: handlerAwsCognitoUserPool,
  aws_efs_file_system: handlerAwsEfsFileSystem,
  aws_efs_access_point: handlerAwsEfsAccessPoint
};

// src/awsValidator.ts
var AwsValidator = class {
  PRIORITY_TYPES = /* @__PURE__ */ new Set(["aws_vpc", "aws_subnet"]);
  collector;
  domainNodeKeys = [];
  constructor(collector2) {
    this.collector = collector2;
  }
  validateNodes(originalNodes, _originalNodeMap, domainNodeKeys) {
    this.domainNodeKeys = domainNodeKeys;
    const nodesCopy = structuredClone(originalNodes);
    const nodeMapCopy = {};
    for (const node of nodesCopy)
      if ("key" in node)
        nodeMapCopy[node.key] = node;
    const priorityNodes = [];
    const otherNodes = [];
    for (const node of nodesCopy) {
      if (this.PRIORITY_TYPES.has(node.type))
        priorityNodes.push(node);
      else
        otherNodes.push(node);
    }
    for (const node of priorityNodes)
      this.dispatchValidation(node, nodeMapCopy);
    for (const node of otherNodes)
      this.dispatchValidation(node, nodeMapCopy);
  }
  dispatchValidation(node, nodeMap) {
    const nodeType = node.type;
    if (!nodeType)
      return;
    const method = this[`_validate_${nodeType}`];
    if (typeof method === "function") {
      try {
        method.call(this, node, nodeMap);
      } catch {
      }
    }
  }
  // ==========================================================================
  _validate_aws_vpc(node, _nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const isGenerated = params["assign_generated_ipv6_cidr_block"] === true;
    const hasCidrBlock = !!params["ipv6_cidr_block"];
    const hasIpam = !!params["ipv6_ipam_pool_id"];
    node["has_ipv6"] = isGenerated || hasCidrBlock || hasIpam;
    return node;
  }
  _validate_aws_subnet(node, nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const connections = node.connections?.target ?? {};
    const nodeId = node.key;
    const azKeys = connections["aws_az_"] ?? [];
    const azNode = nodeMap[azKeys[0]];
    const azSuffix = azNode.cloudResource?.params?.["az_suffix"] ?? "";
    const [, regionName] = findAccountAndRegionName(node, nodeMap);
    const fullAz = `${regionName}${azSuffix}`;
    node.cloudResource.params["availability_zone"] = fullAz;
    const hasIpv4Cidr = !!params["cidr_block"];
    const hasIpv6Cidr = !!params["ipv6_cidr_block"];
    const assignIpv6 = params["assign_ipv6_address_on_creation"] === true;
    if (!(hasIpv4Cidr || hasIpv6Cidr || assignIpv6)) {
      this.collector.addError(["subnet_missing_cidr_block", nodeId]);
    }
    const subnetHasIpv6 = !!params["ipv6_cidr_block"] || params["assign_ipv6_address_on_creation"] === true;
    if (subnetHasIpv6) {
      const vpcKeys = connections["aws_vpc"] ?? [];
      let vpcNode;
      if (vpcKeys.length > 0) {
        vpcNode = nodeMap[vpcKeys[0]];
      } else {
        const parentKey = node["parent"] || node["group"];
        if (parentKey) {
          const potentialVpc = nodeMap[parentKey];
          if (potentialVpc && potentialVpc.type === "aws_vpc")
            vpcNode = potentialVpc;
        }
      }
      if (vpcNode) {
        if (!vpcNode["has_ipv6"])
          this.collector.addError(["vpc_missing_ipv6_config", node.key]);
      } else {
        this.collector.addError(["subnet_orphan_no_vpc_found", node.key]);
      }
    }
    const autoAssignIp = params["map_public_ip_on_launch"] === true;
    const rtKeys = connections["aws_route_table"] ?? [];
    let hasIgwRoute = false;
    for (const rtKey of rtKeys) {
      const rtNode = nodeMap[rtKey];
      if (rtNode) {
        const rtTargets = rtNode.connections?.target ?? {};
        if (rtTargets["aws_internet_gateway"]) {
          hasIgwRoute = true;
          break;
        }
      }
    }
    node["is_public"] = hasIgwRoute;
    if (hasIgwRoute && !autoAssignIp)
      this.collector.addWarning(["subnet_public_no_auto_ip", node.key]);
    if (autoAssignIp && !hasIgwRoute)
      this.collector.addWarning(["subnet_auto_ip_no_igw_route", node.key]);
    return node;
  }
  _validate_aws_lb_Xalb(node, nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const albKey = node.key;
    const connections = node.connections?.target ?? {};
    const connectedSubnetKeys = connections["aws_subnet"] ?? [];
    const subnetNodes = [];
    for (const snKey of connectedSubnetKeys)
      if (snKey in nodeMap)
        subnetNodes.push(nodeMap[snKey]);
    if (subnetNodes.length < 2) {
      this.collector.addError(["alb_min_subnets", albKey]);
      return;
    }
    const usedAzs = {};
    for (const sn of subnetNodes) {
      const az = sn.cloudResource?.params?.["availability_zone"];
      if (az) {
        if (az in usedAzs) {
          this.collector.addError(["alb_duplicate_az", albKey]);
          return;
        }
        usedAzs[az] = sn.logicalName;
      }
    }
    const subnetAzs = /* @__PURE__ */ new Set();
    let hasPrivate = false;
    let hasPublic = false;
    let vpcNode;
    for (const sn of subnetNodes) {
      const snParams = sn.cloudResource?.params ?? {};
      if ("availability_zone" in snParams)
        subnetAzs.add(snParams["availability_zone"]);
      if (sn["is_public"] === true || sn["is_public"]) {
      }
      const isPublic = sn["is_public"] ?? false;
      if (isPublic)
        hasPublic = true;
      else
        hasPrivate = true;
      if (!vpcNode) {
        const vpcKeys = sn.connections?.target?.["aws_vpc"] ?? [];
        if (vpcKeys.length > 0)
          vpcNode = nodeMap[vpcKeys[0]];
      }
    }
    if (subnetAzs.size < 2)
      this.collector.addError(["alb_duplicate_az", albKey]);
    const isInternal = params["internal"] ?? false;
    if (isInternal === false) {
      if (hasPrivate)
        this.collector.addError(["alb_external_private_subnet", albKey]);
    } else {
      if (hasPublic)
        this.collector.addError(["alb_internal_public_subnet", albKey]);
    }
    const ipType = params["ip_address_type"] ?? "ipv4";
    if (ipType === "dualstack" && vpcNode) {
      if (!vpcNode["has_ipv6"])
        this.collector.addError(["alb_dualstack_ipv4_vpc", albKey]);
    }
  }
  _validate_aws_lb_listener(node, nodeMap) {
    const connections = node.connections?.target ?? {};
    const connectedRuleKeys = connections["aws_lb_listener_rule"] ?? [];
    const priorityMap = {};
    for (const ruleKey of connectedRuleKeys) {
      if (ruleKey in nodeMap) {
        const ruleNode = nodeMap[ruleKey];
        const params = ruleNode.cloudResource?.params ?? {};
        const priority = params["priority"];
        if (priority !== null && priority !== void 0) {
          if (!(priority in priorityMap))
            priorityMap[priority] = [];
          priorityMap[priority].push(ruleKey);
        }
      }
    }
    for (const keysList of Object.values(priorityMap)) {
      if (keysList.length > 1) {
        for (const dupKey of keysList)
          this.collector.addError(["listener_rule_duplicate_priority", dupKey]);
      }
    }
  }
  _validate_aws_launch_template(node, _nodeMap) {
    if (this._isImdsVulnerable(node))
      this.collector.addWarning(["instance_imds_v1_vulnerable", node.key]);
  }
  _validate_aws_instance(node, _nodeMap) {
    if (this._isImdsVulnerable(node))
      this.collector.addWarning(["instance_imds_v1_vulnerable", node.key]);
  }
  _isImdsVulnerable(node) {
    const params = node.cloudResource?.params ?? {};
    const metadataOptions = params["metadata_options"];
    let httpEndpoint = null;
    let httpTokens = null;
    let httpProtocolIpv6 = null;
    if (Array.isArray(metadataOptions) && metadataOptions.length > 0) {
      const first = metadataOptions[0];
      if (first && typeof first === "object") {
        httpEndpoint = first["http_endpoint"];
        httpTokens = first["http_tokens"];
        httpProtocolIpv6 = first["http_protocol_ipv6"];
      }
    } else if (metadataOptions && typeof metadataOptions === "object") {
      httpEndpoint = metadataOptions["http_endpoint"];
      httpTokens = metadataOptions["http_tokens"];
      httpProtocolIpv6 = metadataOptions["http_protocol_ipv6"];
    }
    if (httpEndpoint == null)
      httpEndpoint = params["metadata_options.http_endpoint"];
    if (httpTokens == null)
      httpTokens = params["metadata_options.http_tokens"];
    if (httpProtocolIpv6 == null)
      httpProtocolIpv6 = params["metadata_options.http_protocol_ipv6"];
    const endpointVal = httpEndpoint != null ? httpEndpoint : "enabled";
    const tokensVal = httpTokens != null ? httpTokens : "optional";
    const ipv6Val = httpProtocolIpv6 != null ? httpProtocolIpv6 : "disabled";
    const imdsActive = endpointVal === "enabled" || ipv6Val === "enabled";
    return imdsActive && tokensVal !== "required";
  }
  _validate_aws_db_instance(node, nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const targetConnections = node.connections?.target ?? {};
    const sourceConnections = node.connections?.source ?? {};
    const dbKey = node.key;
    const subnetNodes = [];
    for (const snKey of targetConnections["aws_subnet"] ?? [])
      if (snKey in nodeMap)
        subnetNodes.push(nodeMap[snKey]);
    if (subnetNodes.length < 2) {
      this.collector.addError(["rds_min_subnets", dbKey]);
      return;
    }
    const usedAzs = {};
    const subnetAzs = /* @__PURE__ */ new Set();
    for (const sn of subnetNodes) {
      const az = sn.cloudResource?.params?.["availability_zone"];
      const snName = sn.logicalName;
      if (az) {
        if (az in usedAzs) {
          this.collector.addError(["rds_duplicate_az", dbKey]);
          return;
        }
        usedAzs[az] = snName;
        subnetAzs.add(az);
      }
    }
    if (subnetAzs.size < 2)
      this.collector.addError(["rds_insufficient_azs", dbKey]);
    if (params["network_type"] === "DUAL") {
      const vpcKeys = targetConnections["aws_vpc"] ?? [];
      if (vpcKeys.length > 0) {
        const vpcNode = nodeMap[vpcKeys[0]];
        if (vpcNode && !vpcNode["has_ipv6"])
          this.collector.addError(["rds_dualstack_no_ipv6_vpc", dbKey]);
      }
    }
    if (params["storage_type"] === "io1" && !params["iops"])
      this.collector.addError(["rds_io1_missing_iops", dbKey]);
    const allocated = params["allocated_storage"];
    const maxAllocated = params["max_allocated_storage"];
    if (allocated && maxAllocated) {
      const a = parseInt(String(allocated), 10);
      const m = parseInt(String(maxAllocated), 10);
      if (!Number.isNaN(a) && !Number.isNaN(m)) {
        if (m <= a)
          this.collector.addError(["rds_autoscaling_invalid", dbKey]);
      }
    }
    const instanceClass = params["instance_class"] ?? "";
    const piEnabled = params["performance_insights_enabled"] === true;
    const unsupported = ["t2.micro", "t2.small", "t3.micro", "t3.small"];
    if (piEnabled && unsupported.some((x) => String(instanceClass).includes(x))) {
      this.collector.addError(["rds_pi_instance_type", dbKey]);
    }
    if (params["publicly_accessible"] === true)
      this.collector.addWarning(["rds_public_access", dbKey]);
    if (params["storage_encrypted"] === false)
      this.collector.addWarning(["rds_storage_unencrypted", dbKey]);
    const connectedSgs = sourceConnections["aws_security_group"] ?? [];
    if (connectedSgs.length === 0)
      this.collector.addWarning(["rds_default_sg", dbKey]);
    if (params["skip_final_snapshot"] === true)
      this.collector.addWarning(["rds_skip_final_snapshot", dbKey]);
    const backupWin = params["backup_window"];
    const maintWin = params["maintenance_window"];
    if (backupWin && maintWin && backupWin === maintWin)
      this.collector.addWarning(["rds_window_overlap", dbKey]);
    if (subnetNodes.some((sn) => sn["is_public"] === true || sn["is_public"]))
      this.collector.addWarning(["rds_in_public_subnet", dbKey]);
    if (params["apply_immediately"] === true)
      this.collector.addInfo(["rds_apply_immediately", dbKey]);
    if (params["storage_type"] === "gp2")
      this.collector.addInfo(["rds_storage_gp2", dbKey]);
  }
  _validate_aws_efs_file_system(node, nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const efsKey = node.key;
    const targetConnections = node.connections?.target ?? {};
    const subnetNodes = [];
    for (const snKey of targetConnections["aws_subnet"] ?? [])
      if (snKey in nodeMap)
        subnetNodes.push(nodeMap[snKey]);
    if (subnetNodes.length === 0) {
      this.collector.addError(["efs_missing_subnets", efsKey]);
      return;
    }
    const azToSubnet = {};
    let hasPublic = false;
    for (const sn of subnetNodes) {
      if (sn["is_public"] === true)
        hasPublic = true;
      const snTargets = sn.connections?.target ?? {};
      const azNodes = snTargets["aws_az_"] ?? [];
      let azId;
      if (azNodes.length > 0)
        azId = azNodes[0];
      else
        azId = sn.cloudResource?.params?.["availability_zone"] ?? `unknown_az_${sn.key}`;
      if (azId in azToSubnet)
        this.collector.addError(["efs_multiple_subnets_same_az", efsKey]);
      else
        azToSubnet[azId] = sn.logicalName;
    }
    if (hasPublic)
      this.collector.addWarning(["efs_in_public_subnet", efsKey]);
    if (!params["encrypted"])
      this.collector.addWarning(["efs_storage_unencrypted", efsKey]);
    const lifecyclePolicies = params["lifecycle_policy"] ?? [];
    if (Array.isArray(lifecyclePolicies) && lifecyclePolicies.length > 1) {
      const seen = /* @__PURE__ */ new Set();
      let hasDuplicate = false;
      for (const policy of lifecyclePolicies) {
        if (policy && typeof policy === "object") {
          for (const paramName of Object.keys(policy)) {
            if (paramName.endsWith("_"))
              continue;
            if (seen.has(paramName)) {
              this.collector.addError(["efs_duplicate_lifecycle_parameter", efsKey]);
              hasDuplicate = true;
              break;
            }
            seen.add(paramName);
          }
        }
        if (hasDuplicate)
          break;
      }
    }
  }
  _validate_aws_cognito_user_pool(node, _nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const resourceKey = node.key;
    const mfaConfig = params["mfa_configuration"] ?? "OFF";
    if (mfaConfig === "OFF")
      this.collector.addWarning(["cognito_mfa_disabled", resourceKey]);
    const delProt = params["deletion_protection"] ?? "INACTIVE";
    if (delProt === "INACTIVE")
      this.collector.addWarning(["cognito_deletion_protection_inactive", resourceKey]);
    const pwdBlock = params["password_policy"] ?? [];
    let pwdPolicy;
    if (Array.isArray(pwdBlock) && pwdBlock.length > 0)
      pwdPolicy = pwdBlock[0];
    else if (pwdBlock && typeof pwdBlock === "object" && !Array.isArray(pwdBlock))
      pwdPolicy = pwdBlock;
    else
      pwdPolicy = {};
    if (pwdPolicy && Object.keys(pwdPolicy).length > 0) {
      const minLen = parseInt(String(pwdPolicy["minimum_length"] ?? 8), 10);
      const reqLower = pwdPolicy["require_lowercase"] ?? true;
      const reqUpper = pwdPolicy["require_uppercase"] ?? true;
      const reqNum = pwdPolicy["require_numbers"] ?? true;
      const reqSym = pwdPolicy["require_symbols"] ?? true;
      if (minLen < 8)
        this.collector.addWarning(["cognito_password_weak_length", resourceKey]);
      if (!(reqLower && reqUpper && reqNum && reqSym))
        this.collector.addWarning(["cognito_password_weak_complexity", resourceKey]);
    }
  }
  _validate_aws_cognito_user_pool_client(node, _nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const resourceKey = node.key;
    const isOauthClient = params["allowed_oauth_flows_user_pool_client"] ?? false;
    const oauthFlows = params["allowed_oauth_flows"] ?? [];
    const callbackUrls = params["callback_urls"] ?? [];
    const explicitAuthFlows = params["explicit_auth_flows"] ?? [];
    if (isOauthClient) {
      const usesRedirect = ["code", "implicit"].some((f) => oauthFlows.includes(f));
      if (usesRedirect && callbackUrls.length === 0)
        this.collector.addError(["cognito_client_no_callback", resourceKey]);
      if (oauthFlows.length === 0)
        this.collector.addError(["cognito_client_no_flows", resourceKey]);
    }
    if (explicitAuthFlows.includes("ADMIN_NO_SRP_AUTH"))
      this.collector.addWarning(["cognito_client_insecure_auth", resourceKey]);
    const generateSecret = params["generate_secret"] ?? false;
    if (oauthFlows.includes("implicit") && generateSecret)
      this.collector.addWarning(["cognito_client_implicit_secret", resourceKey]);
  }
  // NOTA: prefixo `_validate_x_` -> nunca despachado (dispatch procura
  // `_validate_aws_dynamodb_table`). Portado morto por fidelidade.
  _validate_x_aws_dynamodb_table(node, _nodeMap) {
    const params = node.cloudResource?.params ?? {};
    const resourceKey = node.key;
    const required = /* @__PURE__ */ new Set();
    if ("hash_key" in params)
      required.add(params["hash_key"]);
    if ("range_key" in params)
      required.add(params["range_key"]);
    let gsis = params["global_secondary_index"] ?? [];
    if (gsis && typeof gsis === "object" && !Array.isArray(gsis))
      gsis = [gsis];
    for (const gsi of gsis) {
      if ("hash_key" in gsi)
        required.add(gsi["hash_key"]);
      if ("range_key" in gsi)
        required.add(gsi["range_key"]);
    }
    let lsis = params["local_secondary_index"] ?? [];
    if (lsis && typeof lsis === "object" && !Array.isArray(lsis))
      lsis = [lsis];
    for (const lsi of lsis)
      if ("range_key" in lsi)
        required.add(lsi["range_key"]);
    let definedList = params["attribute"] ?? [];
    if (definedList === null)
      definedList = [];
    else if (definedList && typeof definedList === "object" && !Array.isArray(definedList)) {
      definedList = [definedList];
      params["attribute"] = definedList;
    }
    const existingNames = new Set(definedList.map((attr) => attr?.name));
    let autoFixed = false;
    for (const reqAttr of required) {
      if (!existingNames.has(reqAttr)) {
        if (!("attribute" in params) || params["attribute"] == null)
          params["attribute"] = [];
        params["attribute"].push({ name: reqAttr, type: "S" });
        autoFixed = true;
      }
    }
    if (autoFixed)
      this.collector.addWarning(["dynamodb_attributes_autofixed_string", resourceKey]);
  }
  _validate_aws_s3_bucket_replication_configuration(node, nodeMap) {
    const connections = node.connections ?? {};
    const sourceKeys = connections.source?.["aws_s3_bucket"] ?? [];
    const targetKeys = connections.target?.["aws_s3_bucket"] ?? [];
    const sourceBucket = sourceKeys.length > 0 ? nodeMap[sourceKeys[0]] : null;
    const targetBucket = targetKeys.length > 0 ? nodeMap[targetKeys[0]] : null;
    const checkVersioningEnabled = /* @__PURE__ */ __name((bucketNode) => {
      const bConns = bucketNode.connections ?? {};
      const vKeys = bConns.source?.["aws_s3_bucket_versioning"] ?? [];
      const vNode = nodeMap[vKeys[0]];
      const vParams = vNode.cloudResource?.params ?? {};
      const vConfig = vParams["versioning_configuration"] ?? [];
      if (Array.isArray(vConfig) && vConfig.length > 0)
        return vConfig[0]["status"] === "Enabled";
      return false;
    }, "checkVersioningEnabled");
    if (sourceBucket) {
      if (!checkVersioningEnabled(sourceBucket))
        this.collector.addError(["s3_replication_source_versioning_disabled", sourceBucket.key]);
    }
    if (targetBucket) {
      if (!checkVersioningEnabled(targetBucket))
        this.collector.addError(["s3_replication_target_versioning_disabled", targetBucket.key]);
    }
  }
};
__name(AwsValidator, "AwsValidator");

// src/handlers/network.ts
function handleAwsRoute(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const rtId = params["route_table_id"] ?? "";
  const rtClean = rtId.includes(".") ? rtId.split(".")[1] : "rt";
  let targetClean = "dest";
  let targetType = "";
  const possibleTargets = [
    "gateway_id",
    "egress_only_gateway_id",
    "nat_gateway_id",
    "transit_gateway_id",
    "vpc_endpoint_id",
    "vpc_peering_connection_id",
    "network_interface_id",
    "carrier_gateway_id",
    "local_gateway_id"
  ];
  for (const tgtKey of possibleTargets) {
    const val = params[tgtKey];
    if (val && String(val).trim() !== "") {
      const valStr = String(val);
      targetClean = valStr.includes(".") ? valStr.split(".")[1] : valStr;
      targetType = tgtKey;
      break;
    }
  }
  let ipv4Cidr = params["destination_cidr_block"];
  let ipv6Cidr = params["destination_ipv6_cidr_block"];
  let hasIpv4 = Boolean(ipv4Cidr) && String(ipv4Cidr).trim() !== "";
  let hasIpv6 = Boolean(ipv6Cidr) && String(ipv6Cidr).trim() !== "";
  const rtKeys = node.connections?.source?.["aws_route_table"] ?? [];
  const refId = rtKeys.length > 0 ? rtKeys[0] : node.key;
  let hasIpv6SubnetInRt = false;
  let hasIpv4SubnetInRt = false;
  let subnetKeys = [];
  let hasEgwInRt = false;
  if (rtKeys.length > 0) {
    const rtNode = self.nodeMap?.[rtKeys[0]];
    if (rtNode) {
      hasEgwInRt = Boolean(rtNode.connections?.target?.["aws_egress_only_internet_gateway"]?.length);
      subnetKeys = rtNode.connections?.source?.["aws_subnet"] ?? [];
      for (const subKey of subnetKeys) {
        const subNode = self.nodeMap?.[subKey];
        if (subNode) {
          const subParams = subNode.cloudResource?.params ?? {};
          const subHasIpv6 = Boolean(subParams["ipv6_cidr_block"]) || subParams["assign_ipv6_address_on_creation"] === true || subParams["ipv6_native"] === true;
          if (subHasIpv6)
            hasIpv6SubnetInRt = true;
          const subHasIpv4 = subParams["ipv6_native"] !== true;
          if (subHasIpv4)
            hasIpv4SubnetInRt = true;
        }
      }
    }
  }
  if (hasEgwInRt && targetType === "gateway_id") {
    if (hasIpv6) {
      if (hasIpv4) {
        hasIpv6 = false;
        delete params["destination_ipv6_cidr_block"];
        ipv6Cidr = "";
      } else {
        node.type = "ignored_route";
        node.cloudResource.params = {};
        return node;
      }
    }
  }
  if (targetType === "nat_gateway_id" && hasIpv6) {
    hasIpv6 = false;
    delete params["destination_ipv6_cidr_block"];
    ipv6Cidr = "";
  }
  if (!hasIpv4 && !hasIpv6) {
    node.type = "ignored_route";
    node.cloudResource.params = {};
    return node;
  }
  const targetIgw = params["gateway_id"];
  const targetEgw = params["egress_only_gateway_id"];
  if (targetIgw && targetEgw) {
    self.collector.addError(["route_multiple_gateways_conflict", refId]);
    node.type = "ignored_route";
    return node;
  }
  if (targetEgw && hasIpv4 && !hasIpv6) {
    self.collector.addError(["route_egw_ipv4_not_supported", refId]);
    node.type = "ignored_route";
    return node;
  }
  if (hasIpv4 && subnetKeys.length > 0 && !hasIpv4SubnetInRt) {
    self.collector.addError(["route_ipv4_on_ipv6_only_subnets", refId]);
    node.type = "ignored_route";
    return node;
  }
  if (hasIpv6 && subnetKeys.length > 0 && !hasIpv6SubnetInRt) {
    self.collector.addWarning(["route_ipv6_on_ipv4_only_subnets", refId]);
  }
  if (targetType === "egress_only_gateway_id") {
    if (hasIpv6) {
      node.logicalName = `route_${rtClean}_to_${targetClean}_ipv6`;
      delete params["destination_cidr_block"];
    } else {
      node.type = "ignored_route";
    }
    return node;
  }
  if (hasIpv4 && hasIpv6) {
    node.logicalName = `route_${rtClean}_to_${targetClean}_ipv4`;
    delete params["destination_ipv6_cidr_block"];
    const newLogicalName = `route_${rtClean}_to_${targetClean}_ipv6`;
    const nodeIpv6 = self.addGenericNode(self.nodes, "aws_route", newLogicalName);
    if (nodeIpv6) {
      nodeIpv6.cloudResource.params = {
        route_table_id: rtId,
        [targetType]: params[targetType],
        destination_ipv6_cidr_block: ipv6Cidr
      };
      const conns = node.connections ?? { source: {}, target: {} };
      nodeIpv6.connections = structuredClone(conns);
    }
  } else if (hasIpv6 && !hasIpv4) {
    node.logicalName = `route_${rtClean}_to_${targetClean}_ipv6`;
    delete params["destination_cidr_block"];
  } else if (hasIpv4 && !hasIpv6) {
    node.logicalName = `route_${rtClean}_to_${targetClean}_ipv4`;
    delete params["destination_ipv6_cidr_block"];
  }
  return node;
}
__name(handleAwsRoute, "handleAwsRoute");
function handleAwsNatGateway(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const connections = node.connections?.target ?? {};
  const natLogicalName = node.logicalName;
  const subnetKeys = connections["aws_subnet"] ?? [];
  const makeEip = /* @__PURE__ */ __name((eipLogicalName, tagName) => {
    if (!self.generatedNodes.some((n) => n.logicalName === eipLogicalName)) {
      const eipNode = self.addGenericNode(self.generatedNodes, "aws_eip", eipLogicalName, node, null, true);
      if (eipNode) {
        eipNode.cloudResource ??= {};
        eipNode.cloudResource.params ??= {};
        const eipParams = eipNode.cloudResource.params;
        eipParams["domain"] = "vpc";
        eipParams["tags"] = { Name: tagName };
      }
    }
  }, "makeEip");
  if (subnetKeys.length === 1) {
    params["availability_mode"] = "zonal";
    const subnetNode = self.nodeMap?.[subnetKeys[0]];
    if (subnetNode)
      params["subnet_id"] = `aws_subnet.${subnetNode.logicalName}.id`;
    const eipLogicalName = `eip_${natLogicalName}`.toLowerCase();
    makeEip(eipLogicalName, `eip-${natLogicalName}`.toLowerCase());
    params["allocation_id"] = `aws_eip.${eipLogicalName}.id`;
    delete params["vpc_id"];
  } else {
    params["availability_mode"] = "regional";
    params["connectivity_type"] = "public";
    const vpcKeys = connections["aws_vpc"] ?? [];
    if (vpcKeys.length > 0) {
      const vpcNode = self.nodeMap?.[vpcKeys[0]];
      if (vpcNode)
        params["vpc_id"] = `aws_vpc.${vpcNode.logicalName}.id`;
    }
    if (subnetKeys.length >= 2) {
      const azBlocks = [];
      subnetKeys.forEach((subnetKey, idx) => {
        const subnetNode = self.nodeMap?.[subnetKey];
        if (!subnetNode)
          return;
        const eipLogicalName = `eip_${natLogicalName}_${idx}`.toLowerCase();
        makeEip(eipLogicalName, `eip-${natLogicalName}-${idx}`.toLowerCase());
        azBlocks.push({
          availability_zone: `aws_subnet.${subnetNode.logicalName}.availability_zone`,
          allocation_ids: [`aws_eip.${eipLogicalName}.id`]
        });
      });
      if (azBlocks.length > 0)
        params["availability_zone_address"] = azBlocks;
      else
        delete params["availability_zone_address"];
    } else {
      delete params["availability_zone_address"];
    }
    delete params["subnet_id"];
    delete params["allocation_id"];
    delete params["private_ip"];
    delete params["secondary_allocation_ids"];
    delete params["secondary_private_ip_addresses"];
    delete params["secondary_private_ip_address_count"];
  }
}
__name(handleAwsNatGateway, "handleAwsNatGateway");
function handlePreAwsVpc(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const isGenerated = params["assign_generated_ipv6_cidr_block"] === true;
  const hasCidrBlock = Boolean(params["ipv6_cidr_block"]);
  const hasIpam = Boolean(params["ipv6_ipam_pool_id"]);
  node["has_ipv6"] = isGenerated || hasCidrBlock || hasIpam;
  return node;
}
__name(handlePreAwsVpc, "handlePreAwsVpc");
function handlePreAwsSubnet(self) {
  const node = self.node;
  const connections = node.connections?.target ?? {};
  const azKeys = connections["aws_az_"] ?? [];
  if (azKeys.length === 0) {
    throw new Error("list index out of range");
  }
  const azNode = self.nodeMap?.[azKeys[0]];
  if (!azNode) {
    throw new Error("'NoneType' object has no attribute 'get'");
  }
  const azSuffix = azNode.cloudResource?.params?.["az_suffix"] ?? "";
  const [, regionName] = findAccountAndRegionName(node, self.nodeMap ?? {});
  const fullAz = `${regionName}${azSuffix}`;
  node.cloudResource.params["availability_zone"] = fullAz;
  const rtKeys = connections["aws_route_table"] ?? [];
  let hasIgwRoute = false;
  for (const rtKey of rtKeys) {
    const rtNode = self.nodeMap?.[rtKey];
    if (rtNode) {
      const rtTargets = rtNode.connections?.target ?? {};
      if (rtTargets["aws_internet_gateway"]?.length) {
        hasIgwRoute = true;
        break;
      }
    }
  }
  node["is_public"] = hasIgwRoute;
  return node;
}
__name(handlePreAwsSubnet, "handlePreAwsSubnet");
function handleAwsVpcEndpointGateway(self) {
  const node = self.node;
  const originalLogicalName = node.logicalName;
  node.type = "aws_vpc_endpoint";
  node.logicalName = `${originalLogicalName}_S3`;
  const params = node.cloudResource?.params ?? {};
  params["vpc_endpoint_type"] = "Gateway";
  const networkCtx = self.getConnectedNetworkContext(node, self.nodeMap ?? {});
  const regionName = networkCtx.region_name;
  const vpcKeys = node.connections?.target?.["aws_vpc"] ?? [];
  if (vpcKeys.length > 0) {
    const vpcNode = self.nodeMap?.[vpcKeys[0]];
    params["vpc_id"] = `aws_vpc.${vpcNode?.logicalName}.id`;
  }
  const rtKeys = node.connections?.source?.["aws_route_table"] ?? [];
  const rtIds = rtKeys.filter((k) => self.nodeMap && k in self.nodeMap).map((k) => `aws_route_table.${self.nodeMap[k].logicalName}.id`);
  if (rtIds.length > 0)
    params["route_table_ids"] = rtIds;
  params["service_name"] = `com.amazonaws.${regionName}.s3`;
  if (!("tags" in params) || !isPlainObject2(params["tags"]))
    params["tags"] = {};
  params["tags"]["DifName"] = `${originalLogicalName}`;
  const dynamoLogicalName = `${originalLogicalName}_DynamoDB`;
  const dynamoNode = self.addGenericNode(self.generatedNodes, "aws_vpc_endpoint", dynamoLogicalName, node);
  if (dynamoNode) {
    const dynamoParams = structuredClone(params);
    dynamoParams["service_name"] = `com.amazonaws.${regionName}.dynamodb`;
    dynamoParams["tags"]["Name"] = dynamoLogicalName;
    dynamoNode.cloudResource ??= {};
    dynamoNode.cloudResource.params = dynamoParams;
  }
}
__name(handleAwsVpcEndpointGateway, "handleAwsVpcEndpointGateway");
function configureInterfaceEndpointInstance(self, endpointNode, baseParams, serviceAlias, originalLogicalName, vpcNode, nodeMap) {
  const suffixName = serviceAlias.replaceAll(".", "_").toUpperCase();
  const logicalName = `${originalLogicalName}_${suffixName}`;
  endpointNode.logicalName = logicalName;
  const params = baseParams;
  params["vpc_endpoint_type"] = "Interface";
  params["service_name"] = `com.amazonaws.\${data.aws_region.current.region}.${serviceAlias}`;
  delete params["auto_accept"];
  delete params["resource_configuration_arn"];
  delete params["service_network_arn"];
  if (!("tags" in params) || !isPlainObject2(params["tags"]))
    params["tags"] = {};
  params["tags"]["Name"] = logicalName;
  params["tags"]["DifName"] = originalLogicalName;
  if (vpcNode) {
    params["vpc_id"] = `aws_vpc.${vpcNode.logicalName}.id`;
    const vpcParams = vpcNode.cloudResource?.params ?? {};
    const dnsSupport = vpcParams["enable_dns_support"] ?? true;
    const dnsHostnames = vpcParams["enable_dns_hostnames"] ?? false;
    params["private_dns_enabled"] = Boolean(dnsSupport && dnsHostnames);
  } else {
    params["private_dns_enabled"] = false;
  }
  const sgKeys = endpointNode.connections?.source?.["aws_security_group"] ?? [];
  const sgIds = [];
  if (sgKeys.length > 0) {
    for (const sgKey of sgKeys) {
      if (sgKey in nodeMap)
        sgIds.push(`aws_security_group.${nodeMap[sgKey].logicalName}.id`);
    }
  } else if (vpcNode) {
    const vpcCidr = vpcNode.cloudResource?.params?.["cidr_block"];
    if (vpcCidr) {
      const sgLogicalName = `sg_vpce_${originalLogicalName}`;
      const sgAlreadyExists = self.generatedNodes.some((n) => n.logicalName === sgLogicalName);
      if (!sgAlreadyExists) {
        const newSgNode = self.addGenericNode(self.generatedNodes, "aws_security_group", sgLogicalName, endpointNode);
        if (newSgNode) {
          newSgNode.cloudResource ??= {};
          newSgNode.cloudResource.params ??= {};
          const sgParams = newSgNode.cloudResource.params;
          sgParams["name"] = `vpce-sg-${originalLogicalName.toLowerCase()}`;
          sgParams["description"] = `Auto-generated SG for ${originalLogicalName}`;
          sgParams["vpc_id"] = `aws_vpc.${vpcNode.logicalName}.id`;
          sgParams["ingress"] = [{ description: "Allow HTTPS from VPC", from_port: 443, to_port: 443, protocol: "tcp", cidr_blocks: [vpcCidr] }];
          sgParams["egress"] = [{ description: "Allow all outbound traffic", from_port: 0, to_port: 0, protocol: "-1", cidr_blocks: ["0.0.0.0/0"] }];
          sgParams["tags"] = { Name: sgLogicalName, DifName: originalLogicalName };
        }
      }
      sgIds.push(`aws_security_group.${sgLogicalName}.id`);
    }
  }
  if (sgIds.length > 0)
    params["security_group_ids"] = sgIds;
  endpointNode.cloudResource ??= {};
  endpointNode.cloudResource.params = params;
}
__name(configureInterfaceEndpointInstance, "configureInterfaceEndpointInstance");
function handleAwsVpcEndpointInterface(self) {
  const node = self.node;
  const originalLogicalName = node.logicalName;
  node.type = "aws_vpc_endpoint";
  const baseParams = structuredClone(node.cloudResource?.params ?? {});
  const networkCtx = self.getConnectedNetworkContext(node, self.nodeMap ?? {});
  let vpcNode = null;
  const vpcKeys = node.connections?.target?.["aws_vpc"] ?? [];
  if (vpcKeys.length > 0)
    vpcNode = self.nodeMap?.[vpcKeys[0]] ?? null;
  const subnetNodes = networkCtx.subnet_nodes ?? [];
  if (subnetNodes.length > 0) {
    baseParams["subnet_ids"] = subnetNodes.map((s) => `aws_subnet.${s.logicalName}.id`);
    const totalSubnets = subnetNodes.length;
    let ipv6Count = 0;
    for (const sNode of subnetNodes) {
      const sParams = sNode.cloudResource?.params ?? {};
      if (Boolean(sParams["ipv6_cidr_block"]) || sParams["assign_ipv6_address_on_creation"])
        ipv6Count++;
    }
    if (ipv6Count === totalSubnets && totalSubnets > 0) {
      baseParams["ip_address_type"] = "dualstack";
    } else {
      baseParams["ip_address_type"] = "ipv4";
      if (ipv6Count > 0 && ipv6Count < totalSubnets) {
        self.collector.addWarning(["vpce_ipv4_fallback_mixed_subnets", node.key]);
      }
    }
  } else {
    baseParams["ip_address_type"] = "ipv4";
  }
  const targetConns = node.connections?.target ?? {};
  const awsServiceMap = {
    aws_sns_topic: "sns",
    aws_sqs_queue: "sqs",
    aws_kms_key: "kms",
    aws_secretsmanager_secret: "secretsmanager",
    aws_ecs_cluster: "ecs",
    aws_ecr_repository: "ecr.api"
  };
  const discoveredServices = [];
  for (const [targetType, keys] of Object.entries(targetConns)) {
    if (targetType in awsServiceMap && keys.length > 0) {
      const serviceAlias = awsServiceMap[targetType];
      if (!discoveredServices.includes(serviceAlias))
        discoveredServices.push(serviceAlias);
    }
  }
  if (discoveredServices.length === 0)
    discoveredServices.push("ec2");
  configureInterfaceEndpointInstance(
    self,
    node,
    structuredClone(baseParams),
    discoveredServices[0],
    originalLogicalName,
    vpcNode,
    self.nodeMap ?? {}
  );
  for (let i = 1; i < discoveredServices.length; i++) {
    const currentService = discoveredServices[i];
    const newEndpointNode = self.addGenericNode(
      self.generatedNodes,
      "aws_vpc_endpoint",
      `${originalLogicalName}_${currentService.toUpperCase()}`,
      node
    );
    if (newEndpointNode) {
      configureInterfaceEndpointInstance(
        self,
        newEndpointNode,
        structuredClone(baseParams),
        currentService,
        originalLogicalName,
        vpcNode,
        self.nodeMap ?? {}
      );
    }
  }
  return node;
}
__name(handleAwsVpcEndpointInterface, "handleAwsVpcEndpointInterface");
function resolveSubnetKeys(subnetRefs, nodeMap) {
  const subnetKeys = [];
  for (const ref of subnetRefs) {
    const sName = ref.replaceAll("aws_subnet.", "").replaceAll(".id", "").replaceAll(".arn", "");
    for (const [k, v] of Object.entries(nodeMap)) {
      if (v.type === "aws_subnet" && v.logicalName === sName)
        subnetKeys.push(k);
    }
  }
  return subnetKeys;
}
__name(resolveSubnetKeys, "resolveSubnetKeys");
function obterSubnetsDoRecurso(resourceNode, nodeMap) {
  const subnets = [];
  const connections = resourceNode.connections ?? {};
  for (const direction of ["target", "source"]) {
    subnets.push(...connections[direction]?.["aws_subnet"] ?? []);
  }
  const params = resourceNode.cloudResource?.params ?? {};
  const refs = [...params["subnet_ids"] ?? [], ...params["subnets"] ?? [], ...params["vpc_zone_identifier"] ?? []];
  for (const ref of refs) {
    const sName = String(ref).replaceAll("aws_subnet.", "").split(".")[0];
    for (const [k, v] of Object.entries(nodeMap)) {
      if (v.type === "aws_subnet" && v.logicalName === sName)
        subnets.push(k);
    }
  }
  return [...new Set(subnets)];
}
__name(obterSubnetsDoRecurso, "obterSubnetsDoRecurso");
function getBasePorts(params) {
  const portsMap = params["ports_"] ?? {};
  if (!portsMap || Object.keys(portsMap).length === 0) {
    return [
      [53, "udp", "port_53_udp"],
      [53, "tcp", "port_53_tcp"],
      [123, "udp", "port_123_udp"],
      [80, "tcp", "port_80_tcp"],
      [443, "tcp", "port_443_tcp"]
    ];
  }
  const services = [];
  for (const [portStr, protoStr] of Object.entries(portsMap)) {
    const port = parseInt(portStr, 10);
    const protos = String(protoStr).toLowerCase().split("/");
    for (const p of protos)
      services.push([port, p, `port_${port}_${p}`]);
  }
  return services;
}
__name(getBasePorts, "getBasePorts");
function groupPortsByRanges(portasDetectadas, customRangesRaw) {
  let customRanges = customRangesRaw;
  if (!customRanges || Array.isArray(customRanges) && customRanges.length === 0) {
    return portasDetectadas.map(([p, proto, init]) => [p, p, proto, init]);
  }
  if (typeof customRanges === "string")
    customRanges = [customRanges];
  const rangesParsed = [];
  for (const r of customRanges) {
    const [start, end] = r.split("-").map((x) => parseInt(x, 10));
    rangesParsed.push([start, end]);
  }
  const groupedRules = [];
  for (const [p, proto, init] of portasDetectadas) {
    let matchedRange = null;
    for (const [rStart, rEnd] of rangesParsed) {
      if (rStart <= p && p <= rEnd) {
        matchedRange = [rStart, rEnd];
        break;
      }
    }
    if (matchedRange) {
      const sig = [matchedRange[0], matchedRange[1], proto, init];
      if (!groupedRules.some((g) => g[0] === sig[0] && g[1] === sig[1] && g[2] === sig[2] && g[3] === sig[3])) {
        groupedRules.push(sig);
      }
    } else {
      groupedRules.push([p, p, proto, init]);
    }
  }
  return groupedRules;
}
__name(groupPortsByRanges, "groupPortsByRanges");
function isRuleDuplicate(naclNode, egress, protocol, cidrBlock, fromPortRaw, toPortRaw) {
  if (!naclNode)
    return false;
  const n = naclNode;
  if (!("_registered_rules" in n))
    n["_registered_rules"] = [];
  const fromPort = Number(fromPortRaw);
  const toPort = Number(toPortRaw);
  const proto = String(protocol).toLowerCase();
  const registered = n["_registered_rules"];
  for (const existing of registered) {
    if (existing["egress"] === egress && existing["protocol"] === proto) {
      if (existing["from_port"] <= fromPort && existing["to_port"] >= toPort) {
        if (existing["cidr_block"] === "0.0.0.0/0")
          return true;
        if (existing["cidr_block"] === cidrBlock)
          return true;
      }
    }
  }
  registered.push({ egress, protocol: proto, cidr_block: cidrBlock, from_port: fromPort, to_port: toPort });
  return false;
}
__name(isRuleDuplicate, "isRuleDuplicate");
function ensureGlobalNaclPrescan(self, nodeMap) {
  if (self.naclPrescanDone)
    return;
  for (const v of Object.values(nodeMap)) {
    if (v.type === "aws_network_acl") {
      const vv = v;
      if (!("_allocated_rules" in vv))
        vv["_allocated_rules"] = { ingress: [], egress: [] };
      if (!("_explicit_rules" in vv))
        vv["_explicit_rules"] = { ingress: {}, egress: {} };
    }
  }
  for (const [k, v] of Object.entries(nodeMap)) {
    if (v.type === "aws_network_acl_rule") {
      const params = v.cloudResource?.params ?? {};
      const naclId = params["network_acl_id"] ?? "";
      const ruleNum = params["rule_number"];
      const isEgress = params["egress"] ?? false;
      const direction = isEgress ? "egress" : "ingress";
      if (naclId && ruleNum !== null && ruleNum !== void 0) {
        const naclLog = String(naclId).replaceAll("aws_network_acl.", "").replaceAll(".id", "");
        const targetNacl = Object.values(nodeMap).find((n) => n.type === "aws_network_acl" && n.logicalName === naclLog);
        if (targetNacl) {
          targetNacl["_explicit_rules"][direction][Number(ruleNum)] = k;
        }
      }
    }
  }
  self.naclPrescanDone = true;
}
__name(ensureGlobalNaclPrescan, "ensureGlobalNaclPrescan");
function getResourcesBoundToSg(sgKey, nodeMap) {
  const associatedResources = [];
  const sgNode = nodeMap[sgKey];
  if (!sgNode)
    return associatedResources;
  const validTypes = /* @__PURE__ */ new Set(["aws_instance", "aws_autoscaling_group", "aws_db_instance", "aws_lb_Xalb", "aws_lb", "aws_alb"]);
  const targets = sgNode.connections?.target ?? {};
  for (const [resType, keys] of Object.entries(targets)) {
    if (validTypes.has(resType)) {
      for (const key of keys) {
        const n = nodeMap[key];
        if (n)
          associatedResources.push(n);
      }
    }
  }
  for (const node of Object.values(nodeMap)) {
    if (node.type && validTypes.has(node.type)) {
      const conns = node.connections ?? {};
      for (const direction of ["source", "target"]) {
        if (conns[direction]?.["aws_security_group"]?.includes(sgKey))
          associatedResources.push(node);
      }
    }
  }
  const seen = /* @__PURE__ */ new Set();
  const uniqueResources = [];
  for (const res of associatedResources) {
    if (!seen.has(res.key)) {
      seen.add(res.key);
      uniqueResources.push(res);
    }
  }
  return uniqueResources;
}
__name(getResourcesBoundToSg, "getResourcesBoundToSg");
function resolveSgEndpointsSubnets(endpointKeys, nodeMap) {
  const subnets = [];
  for (const key of endpointKeys) {
    const node = nodeMap[key];
    if (!node)
      continue;
    if (node.type === "aws_security_group") {
      const boundResources = getResourcesBoundToSg(key, nodeMap);
      for (const res of boundResources)
        subnets.push(...obterSubnetsDoRecurso(res, nodeMap));
    } else {
      subnets.push(...obterSubnetsDoRecurso(node, nodeMap));
    }
  }
  return [...new Set(subnets)];
}
__name(resolveSgEndpointsSubnets, "resolveSgEndpointsSubnets");
function dedupTuples(arr) {
  const seen = /* @__PURE__ */ new Set();
  const out = [];
  for (const t of arr) {
    const sig = JSON.stringify(t);
    if (!seen.has(sig)) {
      seen.add(sig);
      out.push(t);
    }
  }
  return out;
}
__name(dedupTuples, "dedupTuples");
function discoverDynamicPorts(selfSubnetKeys, targetSubnetKeys, nodeMap) {
  const portasDetectadas = [];
  for (const val of Object.values(nodeMap)) {
    if (val.type === "aws_autoscaling_group") {
      const asgSubnets = obterSubnetsDoRecurso(val, nodeMap);
      const tgRefs = [];
      const tgArns = val.cloudResource?.params?.["target_group_arns"] ?? [];
      for (const arn of tgArns)
        tgRefs.push(arn.replaceAll("aws_lb_target_group.", "").replaceAll(".arn", ""));
      tgRefs.push(...val.connections?.source?.["aws_lb_target_group"] ?? []);
      tgRefs.push(...val.connections?.target?.["aws_lb_target_group"] ?? []);
      for (const tgRef of [...new Set(tgRefs)]) {
        const tgNode = Object.values(nodeMap).find((v) => v.type === "aws_lb_target_group" && (v.key === tgRef || v.logicalName === tgRef));
        if (tgNode) {
          const tgPort = tgNode.cloudResource?.params?.["port"];
          const tgProtoRaw = String(tgNode.cloudResource?.params?.["protocol"] ?? "HTTP").toLowerCase();
          if (tgPort) {
            const tgProto = ["http", "https", "tcp"].includes(tgProtoRaw) ? "tcp" : tgProtoRaw;
            const albSubnets = [];
            for (const alb of Object.values(nodeMap)) {
              if (alb.type === "aws_lb_Xalb")
                albSubnets.push(...obterSubnetsDoRecurso(alb, nodeMap));
            }
            const isSelfAsg = asgSubnets.some((s) => selfSubnetKeys.includes(s));
            const isTargetAsg = asgSubnets.some((t) => targetSubnetKeys.includes(t));
            const isSelfAlb = albSubnets.some((s) => selfSubnetKeys.includes(s));
            const isTargetAlb = albSubnets.some((t) => targetSubnetKeys.includes(t));
            if (isSelfAsg && isTargetAlb)
              portasDetectadas.push([tgPort, tgProto, false]);
            else if (isTargetAsg && isSelfAlb)
              portasDetectadas.push([tgPort, tgProto, true]);
          }
        }
      }
    }
  }
  for (const val of Object.values(nodeMap)) {
    if (val.type === "cldmn_sg_rule") {
      const ingressRules = val.cloudResource?.params?.["ingress"] ?? [];
      for (const rule of ingressRules) {
        const sgPort = rule["from_port"];
        const sgProtoRaw = String(rule["protocol"] ?? "tcp").toLowerCase();
        if (sgPort) {
          const sgProto = ["http", "https", "tcp"].includes(sgProtoRaw) ? "tcp" : sgProtoRaw;
          const sourcesKeys = [];
          for (const [resType, keys] of Object.entries(val.connections?.source ?? {})) {
            if (resType !== "aws_vpc")
              sourcesKeys.push(...keys);
          }
          const targetsKeys = [];
          for (const [resType, keys] of Object.entries(val.connections?.target ?? {})) {
            if (resType !== "aws_vpc")
              targetsKeys.push(...keys);
          }
          const srcSubs = resolveSgEndpointsSubnets(sourcesKeys, nodeMap);
          const tgtSubs = resolveSgEndpointsSubnets(targetsKeys, nodeMap);
          const isSelfSrc = srcSubs.some((s) => selfSubnetKeys.includes(s));
          const isTargetTgt = tgtSubs.some((t) => targetSubnetKeys.includes(t));
          const isTargetSrc = srcSubs.some((s) => targetSubnetKeys.includes(s));
          const isSelfTgt = tgtSubs.some((t) => selfSubnetKeys.includes(t));
          if (isSelfSrc && isTargetTgt)
            portasDetectadas.push([sgPort, sgProto, true]);
          else if (isTargetSrc && isSelfTgt)
            portasDetectadas.push([sgPort, sgProto, false]);
        }
      }
    }
  }
  return dedupTuples(portasDetectadas);
}
__name(discoverDynamicPorts, "discoverDynamicPorts");
function injectInfraRules(self, node, naclLogicalName, epheFrom, epheTo) {
  const params = node.cloudResource?.params ?? {};
  const infraServices = getBasePorts(params);
  for (const [port, proto, name] of infraServices) {
    const outInfra = self.addGenericNode(self.generatedNodes, "aws_network_acl_rule", `out_infra_${naclLogicalName}_${name}`.toLowerCase(), node, null, true);
    if (outInfra) {
      Object.assign(outInfra.cloudResource.params, {
        network_acl_id: `aws_network_acl.${naclLogicalName}.id`,
        rule_number: self.allocateRuleNumber(node, true, 100),
        egress: true,
        protocol: proto,
        rule_action: "allow",
        cidr_block: "0.0.0.0/0",
        from_port: port,
        to_port: port
      });
    }
  }
  const protocolsToInject = [...new Set(infraServices.map(([, proto]) => proto))].sort();
  for (const proto of protocolsToInject) {
    if (isRuleDuplicate(node, false, proto, "0.0.0.0/0", epheFrom, epheTo))
      continue;
    const logicalNameGeneric = `in_infra_return_${proto}_${naclLogicalName}`.toLowerCase();
    const inInfraRet = self.addGenericNode(self.generatedNodes, "aws_network_acl_rule", logicalNameGeneric, node, null, true);
    if (inInfraRet) {
      Object.assign(inInfraRet.cloudResource.params, {
        network_acl_id: `aws_network_acl.${naclLogicalName}.id`,
        rule_number: self.allocateRuleNumber(node, false, 100),
        egress: false,
        protocol: proto,
        rule_action: "allow",
        cidr_block: "0.0.0.0/0",
        from_port: epheFrom,
        to_port: epheTo
      });
    }
  }
}
__name(injectInfraRules, "injectInfraRules");
function injectPublicInternetRules(self, node, naclLogicalName, epheFrom, epheTo) {
  const params = node.cloudResource?.params ?? {};
  const outboundServices = getBasePorts(params);
  for (const [port, proto, name] of outboundServices) {
    const outNode = self.addGenericNode(self.generatedNodes, "aws_network_acl_rule", `out_internet_${naclLogicalName}_${name}`.toLowerCase(), node, null, true);
    if (outNode) {
      outNode["__isAutoGenerated"] = true;
      Object.assign(outNode.cloudResource.params, {
        network_acl_id: `aws_network_acl.${naclLogicalName}.id`,
        rule_number: self.allocateRuleNumber(node, true, 100),
        egress: true,
        protocol: proto,
        rule_action: "allow",
        cidr_block: "0.0.0.0/0",
        from_port: port,
        to_port: port
      });
    }
  }
  const protocolsToInject = [...new Set(outboundServices.map(([, proto]) => proto))].sort();
  for (const proto of protocolsToInject) {
    if (isRuleDuplicate(node, false, proto, "0.0.0.0/0", epheFrom, epheTo))
      continue;
    const logicalNameGeneric = `in_internet_return_${proto}_${naclLogicalName}_ephemeral`.toLowerCase();
    const inRetNode = self.addGenericNode(self.generatedNodes, "aws_network_acl_rule", logicalNameGeneric, node, null, true);
    if (inRetNode) {
      inRetNode["__isAutoGenerated"] = true;
      Object.assign(inRetNode.cloudResource.params, {
        network_acl_id: `aws_network_acl.${naclLogicalName}.id`,
        rule_number: self.allocateRuleNumber(node, false, 100),
        egress: false,
        protocol: proto,
        rule_action: "allow",
        cidr_block: "0.0.0.0/0",
        from_port: epheFrom,
        to_port: epheTo
      });
    }
  }
}
__name(injectPublicInternetRules, "injectPublicInternetRules");
function discoverAndInjectAlbIngress(self, node, naclLogicalName, selfSubnetKeys, nodeMap, epheFrom, epheTo) {
  const albPortsDetected = [];
  for (const skey of selfSubnetKeys) {
    const subnetLogical = nodeMap[skey]?.logicalName;
    const formattedRef = `aws_subnet.${subnetLogical}.id`;
    for (const val of Object.values(nodeMap)) {
      if (val.type === "aws_lb_Xalb") {
        const albSubnets = val.connections?.target?.["aws_subnet"] ?? [];
        const albParamsSubnets = val.cloudResource?.params?.["subnets"] ?? [];
        if (albSubnets.includes(skey) || albParamsSubnets.includes(formattedRef)) {
          const listeners2 = findAllRecursiveConnections(val.key, ["aws_lb_listener"], nodeMap, "target");
          for (const listener of listeners2) {
            const port = listener.cloudResource?.params?.["port"];
            const protoRaw = String(listener.cloudResource?.params?.["protocol"] ?? "HTTPS").toLowerCase();
            if (port)
              albPortsDetected.push([port, ["http", "https", "tcp"].includes(protoRaw) ? "tcp" : protoRaw]);
          }
        }
      }
    }
  }
  if (albPortsDetected.length > 0) {
    const params = node.cloudResource?.params ?? {};
    const customRanges = params["custom_ranges_"] ?? [];
    const uniqueAlbPorts = dedupTuples(albPortsDetected);
    const portasFormatadas = uniqueAlbPorts.map(([p, proto]) => [p, proto, false]);
    const groupedAlbPorts = groupPortsByRanges(portasFormatadas, customRanges);
    for (const [fromPort, toPort, proto] of groupedAlbPorts) {
      const portLabel = fromPort === toPort ? `${fromPort}` : `${fromPort}_${toPort}`;
      if (!isRuleDuplicate(node, false, proto, "0.0.0.0/0", fromPort, toPort)) {
        const inAlb = self.addGenericNode(
          self.generatedNodes,
          "aws_network_acl_rule",
          `in_public_alb_${naclLogicalName}_${portLabel}`.toLowerCase(),
          node,
          null,
          true
        );
        if (inAlb) {
          Object.assign(inAlb.cloudResource.params, {
            network_acl_id: `aws_network_acl.${naclLogicalName}.id`,
            rule_number: self.allocateRuleNumber(node, false, 100),
            egress: false,
            protocol: proto,
            rule_action: "allow",
            cidr_block: "0.0.0.0/0",
            from_port: fromPort,
            to_port: toPort
          });
        }
      }
      if (!isRuleDuplicate(node, true, proto, "0.0.0.0/0", epheFrom, epheTo)) {
        const outAlbRet = self.addGenericNode(
          self.generatedNodes,
          "aws_network_acl_rule",
          `out_public_alb_return_${naclLogicalName}_${portLabel}`.toLowerCase(),
          node,
          null,
          true
        );
        if (outAlbRet) {
          Object.assign(outAlbRet.cloudResource.params, {
            network_acl_id: `aws_network_acl.${naclLogicalName}.id`,
            rule_number: self.allocateRuleNumber(node, true, 100),
            egress: true,
            protocol: proto,
            rule_action: "allow",
            cidr_block: "0.0.0.0/0",
            from_port: epheFrom,
            to_port: epheTo
          });
        }
      }
    }
  }
}
__name(discoverAndInjectAlbIngress, "discoverAndInjectAlbIngress");
function injectInterNaclRules(self, node, targetNaclNode, naclLogicalName, targetNaclName, fromPort, toPort, protocol, tfPortableCidrSource, tfPortableCidrTarget, epheFrom, epheTo, currentIsInitiator) {
  const portLabel = fromPort === toPort ? `${fromPort}` : `${fromPort}_${toPort}`;
  const sourceNaclTfId = `aws_network_acl.${naclLogicalName}.id`;
  const targetNaclTfId = `aws_network_acl.${targetNaclName}.id`;
  let selfEgressPort, selfEgressToPort, selfIngressPort, selfIngressToPort;
  let targetIngressPort, targetIngressToPort, targetEgressPort, targetEgressToPort;
  if (currentIsInitiator) {
    selfEgressPort = fromPort;
    selfEgressToPort = toPort;
    selfIngressPort = epheFrom;
    selfIngressToPort = epheTo;
    targetIngressPort = fromPort;
    targetIngressToPort = toPort;
    targetEgressPort = epheFrom;
    targetEgressToPort = epheTo;
  } else {
    selfEgressPort = epheFrom;
    selfEgressToPort = epheTo;
    selfIngressPort = fromPort;
    selfIngressToPort = toPort;
    targetIngressPort = epheFrom;
    targetIngressToPort = epheTo;
    targetEgressPort = fromPort;
    targetEgressToPort = toPort;
  }
  const outSuffix = currentIsInitiator ? "" : "_return";
  const retSuffix = currentIsInitiator ? "_return" : "";
  const inSuffix = currentIsInitiator ? "" : "_return";
  const destRetSuffix = currentIsInitiator ? "_return" : "";
  if (!isRuleDuplicate(node, true, protocol, tfPortableCidrTarget, selfEgressPort, selfEgressToPort)) {
    const outNode = self.addGenericNode(
      self.generatedNodes,
      "aws_network_acl_rule",
      `out_${naclLogicalName}_to_${targetNaclName}_${protocol}_${portLabel}${outSuffix}`.toLowerCase(),
      node,
      null,
      true
    );
    if (outNode) {
      outNode["__isAutoGenerated"] = true;
      Object.assign(outNode.cloudResource.params, {
        network_acl_id: sourceNaclTfId,
        rule_number: self.allocateRuleNumber(node, true, 100),
        egress: true,
        protocol,
        rule_action: "allow",
        cidr_block: tfPortableCidrTarget,
        from_port: selfEgressPort,
        to_port: selfEgressToPort
      });
    }
  }
  if (!isRuleDuplicate(node, false, protocol, tfPortableCidrTarget, selfIngressPort, selfIngressToPort)) {
    const retNode = self.addGenericNode(
      self.generatedNodes,
      "aws_network_acl_rule",
      `in_ret_${naclLogicalName}_from_${targetNaclName}_${protocol}_${portLabel}${retSuffix}`.toLowerCase(),
      node,
      null,
      true
    );
    if (retNode) {
      retNode["__isAutoGenerated"] = true;
      Object.assign(retNode.cloudResource.params, {
        network_acl_id: sourceNaclTfId,
        rule_number: self.allocateRuleNumber(node, false, 100),
        egress: false,
        protocol,
        rule_action: "allow",
        cidr_block: tfPortableCidrTarget,
        from_port: selfIngressPort,
        to_port: selfIngressToPort
      });
    }
  }
  if (!isRuleDuplicate(targetNaclNode, false, protocol, tfPortableCidrSource, targetIngressPort, targetIngressToPort)) {
    const inNode = self.addGenericNode(
      self.generatedNodes,
      "aws_network_acl_rule",
      `in_${targetNaclName}_from_${naclLogicalName}_${protocol}_${portLabel}${inSuffix}`.toLowerCase(),
      node,
      null,
      true
    );
    if (inNode) {
      inNode["__isAutoGenerated"] = true;
      Object.assign(inNode.cloudResource.params, {
        network_acl_id: targetNaclTfId,
        rule_number: self.allocateRuleNumber(targetNaclNode, false, 100),
        egress: false,
        protocol,
        rule_action: "allow",
        cidr_block: tfPortableCidrSource,
        from_port: targetIngressPort,
        to_port: targetIngressToPort
      });
    }
  }
  if (!isRuleDuplicate(targetNaclNode, true, protocol, tfPortableCidrSource, targetEgressPort, targetEgressToPort)) {
    const destRetNode = self.addGenericNode(
      self.generatedNodes,
      "aws_network_acl_rule",
      `out_ret_${targetNaclName}_to_${naclLogicalName}_${protocol}_${portLabel}${destRetSuffix}`.toLowerCase(),
      node,
      null,
      true
    );
    if (destRetNode) {
      destRetNode["__isAutoGenerated"] = true;
      Object.assign(destRetNode.cloudResource.params, {
        network_acl_id: targetNaclTfId,
        rule_number: self.allocateRuleNumber(targetNaclNode, true, 100),
        egress: true,
        protocol,
        rule_action: "allow",
        cidr_block: tfPortableCidrSource,
        from_port: targetEgressPort,
        to_port: targetEgressToPort
      });
    }
  }
}
__name(injectInterNaclRules, "injectInterNaclRules");
function injectBroadIntraRules(self, node, naclLogicalName, tfCidr) {
  const sourceNaclTfId = `aws_network_acl.${naclLogicalName}.id`;
  const inIntra = self.addGenericNode(self.generatedNodes, "aws_network_acl_rule", `in_intra_${naclLogicalName}_allow_all`.toLowerCase(), node, null, true);
  if (inIntra) {
    inIntra["__isAutoGenerated"] = true;
    Object.assign(inIntra.cloudResource.params, {
      network_acl_id: sourceNaclTfId,
      rule_number: self.allocateRuleNumber(node, false, 200),
      egress: false,
      protocol: "-1",
      from_port: 0,
      to_port: 0,
      rule_action: "allow",
      cidr_block: tfCidr
    });
  }
  const outIntra = self.addGenericNode(self.generatedNodes, "aws_network_acl_rule", `out_intra_${naclLogicalName}_allow_all`.toLowerCase(), node, null, true);
  if (outIntra) {
    outIntra["__isAutoGenerated"] = true;
    Object.assign(outIntra.cloudResource.params, {
      network_acl_id: sourceNaclTfId,
      rule_number: self.allocateRuleNumber(node, true, 200),
      egress: true,
      protocol: "-1",
      from_port: 0,
      to_port: 0,
      rule_action: "allow",
      cidr_block: tfCidr
    });
  }
}
__name(injectBroadIntraRules, "injectBroadIntraRules");
function handlePreAwsNetworkAcl(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const connections = node.connections?.target ?? {};
  const naclLogicalName = node.logicalName;
  ensureGlobalNaclPrescan(self, self.nodeMap ?? {});
  const selfSubnetKeys = resolveSubnetKeys(params["subnet_ids"] ?? [], self.nodeMap ?? {});
  if (selfSubnetKeys.length === 0)
    return node;
  const enableIntra = params["enable_intra_traffic_"] ?? false;
  if (enableIntra) {
    const spanningCidr = self.calcularSpanningCidr(selfSubnetKeys, self.nodeMap ?? {});
    const tfCidr = self.gerarTfCidr(spanningCidr, node, self.nodeMap ?? {});
    injectBroadIntraRules(self, node, naclLogicalName, tfCidr);
  }
  const ephemeralRange = params["ephemeral_ports_"] ?? "32768-61000";
  const [epheFrom, epheTo] = String(ephemeralRange).split("-").map((x) => parseInt(x, 10));
  let isNaclPublic = false;
  for (const skey of selfSubnetKeys) {
    const subnetNode = self.nodeMap?.[skey];
    if (subnetNode?.["is_public"] === true) {
      isNaclPublic = true;
      break;
    }
  }
  if (isNaclPublic) {
    injectPublicInternetRules(self, node, naclLogicalName, epheFrom, epheTo);
  } else {
    injectInfraRules(self, node, naclLogicalName, epheFrom, epheTo);
  }
  discoverAndInjectAlbIngress(self, node, naclLogicalName, selfSubnetKeys, self.nodeMap ?? {}, epheFrom, epheTo);
  const connectedNaclKeys = [...new Set(connections["aws_network_acl"] ?? [])];
  for (const targetNaclKey of connectedNaclKeys) {
    if (targetNaclKey === node.key)
      continue;
    const targetNaclNode = self.nodeMap?.[targetNaclKey];
    if (!targetNaclNode)
      continue;
    const targetNaclName = targetNaclNode.logicalName;
    if (targetNaclName === naclLogicalName)
      continue;
    const targetSubnetRefs = targetNaclNode.cloudResource?.params?.["subnet_ids"] ?? [];
    const targetSubnetKeys = resolveSubnetKeys(targetSubnetRefs, self.nodeMap ?? {});
    if (targetSubnetKeys.length === 0)
      continue;
    const supernetCidr = self.calcularSpanningCidr(targetSubnetKeys, self.nodeMap ?? {});
    const tfPortableCidrTarget = self.gerarTfCidr(supernetCidr, node, self.nodeMap ?? {});
    const selfSupernet = self.calcularSpanningCidr(selfSubnetKeys, self.nodeMap ?? {});
    const tfPortableCidrSource = self.gerarTfCidr(selfSupernet, node, self.nodeMap ?? {});
    const portasDetectadas = discoverDynamicPorts(selfSubnetKeys, targetSubnetKeys, self.nodeMap ?? {});
    const customRangesRaw = params["custom_ranges_"] ?? [];
    const groupedPorts = groupPortsByRanges(portasDetectadas, customRangesRaw);
    for (const [fromPort, toPort, protocol, currentIsInitiator] of groupedPorts) {
      injectInterNaclRules(
        self,
        node,
        targetNaclNode,
        naclLogicalName,
        targetNaclName,
        fromPort,
        toPort,
        protocol,
        tfPortableCidrSource,
        tfPortableCidrTarget,
        epheFrom,
        epheTo,
        currentIsInitiator
      );
    }
  }
  return node;
}
__name(handlePreAwsNetworkAcl, "handlePreAwsNetworkAcl");
function resolveSubnetsFromCidrList(cidrList, nodeMap) {
  const subnetKeys = [];
  for (const item of cidrList) {
    if (typeof item !== "string")
      continue;
    const cleanName = item.replaceAll("aws_subnet.", "").replaceAll(".id", "").replaceAll(".cidr_block", "").trim();
    for (const [k, v] of Object.entries(nodeMap)) {
      if (v.type === "aws_subnet" && v.logicalName === cleanName)
        subnetKeys.push(k);
    }
  }
  return [...new Set(subnetKeys)];
}
__name(resolveSubnetsFromCidrList, "resolveSubnetsFromCidrList");
function generateDeterministicName(ruleParams, baseLogicalName) {
  const direction = ruleParams["egress"] ? "egress" : "ingress";
  const cidrVal = String(ruleParams["cidr_block"] ?? "");
  let targetName;
  if (cidrVal.startsWith("aws_") || cidrVal.startsWith("data.")) {
    const parts2 = cidrVal.split(".");
    targetName = parts2.length >= 2 ? parts2[1] : cidrVal.replaceAll(".", "_");
  } else {
    targetName = cidrVal.replace(/[^a-zA-Z0-9]/g, "_").replace(/_+/g, "_").replace(/^_+|_+$/g, "");
    if (!targetName)
      targetName = "ipv6_any";
  }
  const proto = String(ruleParams["protocol"] ?? "tcp").toLowerCase();
  const protoName = proto === "-1" ? "all_proto" : proto;
  let portName = "";
  if (proto === "tcp" || proto === "udp" || /^\d+$/.test(proto)) {
    const fPort = ruleParams["from_port"] ?? 0;
    const tPort = ruleParams["to_port"] ?? 0;
    if (fPort === 0 && tPort === 0)
      portName = "all_ports";
    else if (fPort === tPort)
      portName = `port_${fPort}`;
    else
      portName = `ports_${fPort}_${tPort}`;
  } else if (proto === "icmp" || proto === "icmpv6") {
    const iType = ruleParams["icmp_type"] ?? -1;
    const iCode = ruleParams["icmp_code"] ?? -1;
    portName = `type_${iType}_code_${iCode}`;
  }
  const parts = [baseLogicalName, direction, targetName, protoName];
  if (portName)
    parts.push(portName);
  const finalName = parts.join("_");
  return finalName.replace(/_+/g, "_").replace(/^_+|_+$/g, "");
}
__name(generateDeterministicName, "generateDeterministicName");
function handleAwsNetworkAclRule(self) {
  const node = self.node;
  if (node["__isAutoGenerated"])
    return node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const baseLogicalName = node.logicalName ?? "Rule";
  const naclId = params["network_acl_id"] ?? "";
  const currentNodeId = node.key ?? "";
  const naclLogical = String(naclId).replaceAll("aws_network_acl.", "").replaceAll(".id", "");
  const parentNaclNode = Object.values(nodeMap).find((n) => n.type === "aws_network_acl" && n.logicalName === naclLogical) ?? null;
  let cidrBlocks = "cidr_block" in params ? params["cidr_block"] : ["0.0.0.0/0"];
  if (!Array.isArray(cidrBlocks))
    cidrBlocks = [cidrBlocks];
  if (cidrBlocks.length > 1) {
    const resolvedSubnetKeys = resolveSubnetsFromCidrList(cidrBlocks, nodeMap);
    if (resolvedSubnetKeys.length > 1 && parentNaclNode) {
      const supernetCidr = self.calcularSpanningCidr(resolvedSubnetKeys, nodeMap);
      const tfCidrExpression = self.gerarTfCidr(supernetCidr, parentNaclNode, nodeMap);
      cidrBlocks = [tfCidrExpression];
    }
  }
  const generatedRulesParams = [];
  const baseRuleNumber = Number.parseInt(String(params["rule_number"] ?? 100), 10);
  const mainIsEgress = params["egress"] ?? false;
  for (const cidr of cidrBlocks) {
    const ruleData = structuredClone(params);
    delete ruleData["additional_rule_"];
    ruleData["cidr_block"] = cidr;
    ruleData["egress"] = mainIsEgress;
    generatedRulesParams.push(ruleData);
  }
  let additionalRules = params["additional_rule_"] ?? [];
  if (isPlainObject2(additionalRules))
    additionalRules = [additionalRules];
  for (const addRule of additionalRules) {
    if (!addRule || Object.keys(addRule).every((k) => k === "network_acl_id"))
      continue;
    const ruleType = addRule["type"] ?? "ingress";
    const egressStates = ruleType === "both" ? [true, false] : [ruleType === "egress"];
    let addCidrBlocks = addRule["cidr_block"] ?? cidrBlocks;
    if (!Array.isArray(addCidrBlocks))
      addCidrBlocks = [addCidrBlocks];
    for (const state of egressStates) {
      for (const cidr of addCidrBlocks) {
        const ruleData = structuredClone(addRule);
        delete ruleData["type"];
        ruleData["network_acl_id"] = naclId;
        ruleData["cidr_block"] = cidr;
        ruleData["egress"] = state;
        if (!("protocol" in ruleData))
          ruleData["protocol"] = "tcp";
        if (!("from_port" in ruleData))
          ruleData["from_port"] = 0;
        if (!("to_port" in ruleData))
          ruleData["to_port"] = 0;
        if (!("rule_action" in ruleData))
          ruleData["rule_action"] = params["rule_action"] ?? "allow";
        generatedRulesParams.push(ruleData);
      }
    }
  }
  let activeRuleNumber = baseRuleNumber;
  generatedRulesParams.forEach((ruleData, index) => {
    const isEgress = ruleData["egress"] ?? false;
    activeRuleNumber = self.allocateRuleNumber(parentNaclNode, isEgress, activeRuleNumber, currentNodeId);
    ruleData["rule_number"] = activeRuleNumber;
    const deterministicLogicalName = generateDeterministicName(ruleData, baseLogicalName);
    if (index === 0) {
      for (const k of Object.keys(params))
        delete params[k];
      Object.assign(params, ruleData);
      node.logicalName = deterministicLogicalName;
    } else if (!self.generatedNodes.some((n) => n.logicalName === deterministicLogicalName)) {
      const newNode = self.addGenericNode(self.generatedNodes, "aws_network_acl_rule", deterministicLogicalName, node, null, true);
      if (newNode)
        newNode.cloudResource.params = ruleData;
    }
  });
  return node;
}
__name(handleAwsNetworkAclRule, "handleAwsNetworkAclRule");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_route() {
    return handleAwsRoute(this);
  },
  handle_aws_nat_gateway() {
    return handleAwsNatGateway(this);
  },
  handle_pre_aws_vpc() {
    return handlePreAwsVpc(this);
  },
  handle_pre_aws_subnet() {
    return handlePreAwsSubnet(this);
  },
  handle_aws_vpc_endpoint_gateway() {
    return handleAwsVpcEndpointGateway(this);
  },
  handle_aws_vpc_endpoint_interface() {
    return handleAwsVpcEndpointInterface(this);
  },
  handle_pre_aws_network_acl() {
    return handlePreAwsNetworkAcl(this);
  },
  handle_aws_network_acl_rule() {
    return handleAwsNetworkAclRule(this);
  }
});

// src/handlers/compute.ts
var LAMBDA_PRINCIPAL_MAP = {
  aws_api_gateway_rest_api: "apigateway.amazonaws.com",
  aws_s3_bucket: "s3.amazonaws.com",
  aws_cloudwatch_event_rule: "events.amazonaws.com",
  aws_sns_topic: "sns.amazonaws.com",
  aws_lb_target_group: "elasticloadbalancing.amazonaws.com",
  aws_lambda_function: "lambda.amazonaws.com",
  aws_sqs_queue: "sqs.amazonaws.com",
  aws_appsync_graphql_api: "appsync.amazonaws.com",
  aws_cognito_user_pool: "cognito-idp.amazonaws.com"
};
function resolveAmiDataSource(self, node) {
  const params = node.cloudResource?.params ?? {};
  if (params["ami"])
    return;
  const filterName = params["ami_filter_name_"];
  if (!filterName)
    return;
  const instanceLogicalName = node.logicalName;
  const dsLogicalName = `AMI_Data_Source_${instanceLogicalName}`;
  const dsConfig = {
    XTYPE: "aws_ami",
    logicalName: dsLogicalName,
    most_recent: true,
    owners: [params["ami_filter_owner_"] || "amazon"],
    filter: [{ name: "name", values: [filterName] }]
  };
  const arch2 = params["ami_filter_arch_"];
  if (arch2 && arch2 !== "*")
    dsConfig["filter"].push({ name: "architecture", values: [arch2] });
  const virt = params["ami_filter_virt_"];
  if (virt && virt !== "*")
    dsConfig["filter"].push({ name: "virtualization-type", values: [virt] });
  self.hcl.addEmbeddedDataSource(node, dsConfig);
  params["ami"] = `data.aws_ami.${dsLogicalName}.id`;
}
__name(resolveAmiDataSource, "resolveAmiDataSource");
function configureInstanceUserData(self, node, envVars, shouldInject) {
  const params = node.cloudResource?.params ?? {};
  const uiState = params;
  const rawFilePath = String(uiState["user_data_file_path_"] ?? "").trim();
  const connections = node.connections?.source ?? {};
  const githubKeys = connections["cldmn_github"] ?? [];
  const hasGithubSource = githubKeys.length > 0;
  const hasFilePath = rawFilePath.length > 1;
  let scriptContentBlock = "";
  let ecsEnvVar = "";
  if (node.type === "aws_launch_template") {
    const asgKey = node.connections?.target?.["aws_autoscaling_group"] ?? [];
    if (asgKey.length > 0) {
      const asgNode = self.nodeMap?.[asgKey[0]];
      const serviceKey = asgNode?.connections?.source?.["aws_ecs_service"] ?? [];
      if (serviceKey.length > 0) {
        const serviceNode = self.nodeMap?.[serviceKey[0]];
        const clusterKey = serviceNode?.connections?.target?.["aws_ecs_cluster"] ?? [];
        const clusterNode = self.nodeMap?.[clusterKey[0]];
        const clusterLogicalName = clusterNode?.logicalName;
        ecsEnvVar = `echo ECS_CLUSTER='${clusterLogicalName}' >> /etc/ecs/ecs.config`;
      }
    }
  }
  let localFileDef = null;
  const instanceLogicalName = node.logicalName;
  const localFileLogicalName = `UserData_${instanceLogicalName}`;
  if (hasGithubSource && hasFilePath) {
    const githubNode = self.nodeMap?.[githubKeys[0]];
    if (githubNode) {
      const ghParams = githubNode.cloudResource?.params ?? {};
      const githubRepo = ghParams["github_repository"] ?? "";
      const cleanPath = rawFilePath.replaceAll('"', "").replaceAll("'", "").replaceAll("\\", "/").replace(/^\/+/, "");
      const fullSourcePath = `\${path.module}/.external_modules/${githubRepo}/${cleanPath}`;
      localFileDef = { XTYPE: "local_file", logicalName: localFileLogicalName, filename: fullSourcePath };
    }
  } else if (hasFilePath) {
    const cleanPath = rawFilePath.replaceAll('"', "").replaceAll("'", "").replaceAll("\\", "/").replace(/^\/+/, "");
    let fullSourcePath = `\${path.module}/${cleanPath}`;
    if (fullSourcePath.endsWith("/"))
      fullSourcePath = fullSourcePath.replace(/\/+$/, "");
    localFileDef = { XTYPE: "local_file", logicalName: localFileLogicalName, filename: fullSourcePath };
  }
  if (localFileDef) {
    self.hcl.addEmbeddedDataSource(node, localFileDef);
    scriptContentBlock = `\${data.local_file.${localFileLogicalName}.content}`;
  } else {
    const userInputText = params["user_data_base64"] || params["user_data"] || "";
    const inputLines = String(userInputText).split("\n");
    if (inputLines.length > 0 && inputLines[0].trim().startsWith("#!")) {
      scriptContentBlock = inputLines.slice(1).join("\n");
    } else {
      scriptContentBlock = String(userInputText);
    }
  }
  const finalScriptLines = ["#!/bin/bash", ""];
  if (shouldInject) {
    finalScriptLines.push("# --- BEGIN STRUCT8 VARIABLES ---");
    if (ecsEnvVar)
      finalScriptLines.push(ecsEnvVar);
    if (envVars && Object.keys(envVars).length > 0) {
      const envFilePath = "/etc/struct8_env";
      finalScriptLines.push(`cat << 'EOFENV' > ${envFilePath}`);
      for (const [key, value] of Object.entries(envVars)) {
        const safeValue = String(value).replaceAll('"', '\\"');
        finalScriptLines.push(`${key}="${safeValue}"`);
      }
      finalScriptLines.push("EOFENV");
      finalScriptLines.push(`cat ${envFilePath} >> /etc/environment`);
      finalScriptLines.push(`sed 's/^/export /' ${envFilePath} > /etc/profile.d/struct8_vars.sh`);
      finalScriptLines.push("chmod +x /etc/profile.d/struct8_vars.sh");
      finalScriptLines.push(`chmod 644 ${envFilePath}`);
    }
    finalScriptLines.push("# --- END STRUCT8 VARIABLES ---");
    finalScriptLines.push("");
  }
  finalScriptLines.push(scriptContentBlock);
  const fullContent = finalScriptLines.join("\n");
  params["user_data_base64"] = `base64encode(<<-EOFUData
${fullContent}
EOFUData
)`;
  if ("user_data" in params)
    delete params["user_data"];
}
__name(configureInstanceUserData, "configureInstanceUserData");
function handleAwsInstance(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const shouldInject = params["add_environment_variables_"] ?? false;
  const envVars = self.processPayloadEnvVars(node);
  configureInstanceUserData(self, node, envVars, shouldInject);
  resolveAmiDataSource(self, node);
}
__name(handleAwsInstance, "handleAwsInstance");
function resolveConnectedInstanceProfile(self, targetNode, params) {
  if (!targetNode)
    return;
  const sources = targetNode.connections?.source ?? {};
  const profileIds = sources["aws_iam_instance_profile"] ?? [];
  if (profileIds.length > 0) {
    const profileNode = self.nodeMap?.[profileIds[0]];
    if (profileNode) {
      params["iam_instance_profile"] = [{ name: `aws_iam_instance_profile.${profileNode.logicalName}.name` }];
    }
  }
}
__name(resolveConnectedInstanceProfile, "resolveConnectedInstanceProfile");
function resolveConnectedSecurityGroups(self, targetNode, params) {
  if (!targetNode)
    return;
  const targetSources = targetNode.connections?.source ?? {};
  const sgIds = targetSources["aws_security_group"] ?? [];
  if (sgIds.length === 0)
    return;
  const sgReferences = [];
  for (const sid of sgIds) {
    const sgNode = self.nodeMap?.[sid];
    if (sgNode)
      sgReferences.push(`aws_security_group.${sgNode.logicalName}.id`);
  }
  if (sgReferences.length === 0)
    return;
  if ("network_interfaces" in params && Array.isArray(params["network_interfaces"]) && params["network_interfaces"].length > 0) {
    for (const ni of params["network_interfaces"])
      ni["security_groups"] = sgReferences;
  } else {
    params["vpc_security_group_ids"] = sgReferences;
  }
}
__name(resolveConnectedSecurityGroups, "resolveConnectedSecurityGroups");
function handleAwsLaunchTemplate(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const shouldInject = params["add_enviorment_variables_"] ?? false;
  let envVars = {};
  const validConsumers = ["aws_autoscaling_group", "aws_instance", "aws_ec2_fleet", "aws_spot_fleet_request", "aws_eks_node_group"];
  let targetNode = null;
  const targets = node.connections?.target ?? {};
  for (const consumerType of validConsumers) {
    if (consumerType in targets) {
      const consumerIds = targets[consumerType];
      if (consumerIds.length > 0) {
        targetNode = self.nodeMap?.[consumerIds[0]] ?? null;
        break;
      }
    }
  }
  if (targetNode) {
    const ltEnvConfig = params["environment_variables"];
    if (ltEnvConfig) {
      const targetParams = targetNode.cloudResource?.params ?? {};
      targetParams["environment_variables"] = ltEnvConfig;
      if ("environment_variables" in params)
        delete params["environment_variables"];
      envVars = self.processPayloadEnvVars(targetNode);
    }
  } else {
    if ("environment_variables" in params)
      delete params["environment_variables"];
    envVars = {};
  }
  configureInstanceUserData(self, node, envVars, shouldInject);
  if ("user_data_base64" in params) {
    params["user_data"] = params["user_data_base64"];
    delete params["user_data_base64"];
  }
  resolveAmiDataSource(self, node);
  if ("ami" in params) {
    params["image_id"] = params["ami"];
    delete params["ami"];
  }
  if ("ebs_optimized" in params) {
    const val = String(params["ebs_optimized"]).toLowerCase();
    if (val === "true")
      params["ebs_optimized"] = true;
    else if (val === "false")
      params["ebs_optimized"] = false;
  }
  resolveConnectedInstanceProfile(self, targetNode, params);
  resolveConnectedSecurityGroups(self, targetNode, params);
  if (targetNode && targetNode.type === "aws_eks_node_group") {
    delete params["ami"];
    delete params["image_id"];
    delete params["user_data"];
    const ngSources = targetNode.connections?.source ?? {};
    const eksClusterIds = ngSources["aws_eks_cluster"] ?? [];
    if (eksClusterIds.length > 0) {
      const eksClusterNode = self.nodeMap?.[eksClusterIds[0]];
      const clusterLogicalName = eksClusterNode?.logicalName;
      if (clusterLogicalName) {
        const clusterSgRef = `aws_eks_cluster.${clusterLogicalName}.vpc_config[0].cluster_security_group_id`;
        if (!("vpc_security_group_ids" in params))
          params["vpc_security_group_ids"] = [];
        else if (!Array.isArray(params["vpc_security_group_ids"]))
          params["vpc_security_group_ids"] = [params["vpc_security_group_ids"]];
        if (!params["vpc_security_group_ids"].includes(clusterSgRef))
          params["vpc_security_group_ids"].push(clusterSgRef);
      }
    }
  }
}
__name(handleAwsLaunchTemplate, "handleAwsLaunchTemplate");
function ensureLambdaHandler(node) {
  const params = node.cloudResource?.params ?? {};
  const handler = params["handler"] ?? "";
  if (handler && String(handler).trim() !== "") {
    params["handler"] = String(handler).replaceAll("\\", ".").replaceAll("/", ".");
    return;
  }
  const filePath = params["file_path_"] ?? "";
  const cleanPath = normalizePath(String(filePath));
  const fileName = !cleanPath ? "index" : cleanPath.split("/").pop();
  params["handler"] = `${fileName}.lambda_handler`;
}
__name(ensureLambdaHandler, "ensureLambdaHandler");
function processGithubArchive(self, lambdaNode) {
  const connections = lambdaNode.connections?.source ?? {};
  const githubKeys = connections["cldmn_github"] ?? [];
  if (githubKeys.length === 0)
    return;
  const githubNode = self.nodeMap?.[githubKeys[0]];
  if (!githubNode)
    return;
  const ghParams = githubNode.cloudResource?.params ?? {};
  const githubRepo = ghParams["github_repository"] ?? "";
  const lambdaUi = lambdaNode.cloudResource?.params ?? {};
  const filePath = normalizePath(String(lambdaUi["file_path_"] ?? ""));
  const lambdaLogicalName = lambdaNode.logicalName;
  const params = lambdaNode.cloudResource?.params ?? {};
  const rawPath = `\${path.module}/.external_modules/${githubRepo}/${filePath}`;
  const fullSourcePath = normalizePath(rawPath);
  if (filePath.toLowerCase().endsWith(".zip")) {
    params["filename"] = fullSourcePath;
    params["source_code_hash"] = `\${filebase64sha256("${fullSourcePath}")}`;
    delete lambdaNode["_temp_data_source_definition"];
  } else {
    const archiveName = `archive_${githubRepo}_${lambdaLogicalName}`;
    lambdaNode["_temp_data_source_definition"] = {
      XTYPE: "archive_file",
      logicalName: archiveName,
      type: "zip",
      source_dir: fullSourcePath,
      output_path: `\${path.module}/${githubRepo}_${lambdaLogicalName}.zip`
    };
    params["filename"] = `data.archive_file.${archiveName}.output_path`;
    params["source_code_hash"] = `data.archive_file.${archiveName}.output_base64sha256`;
    self.registerRequiredProvider("archive_file");
  }
}
__name(processGithubArchive, "processGithubArchive");
function configureLambdaEdgeLogic(self, node) {
  const connections = node.connections?.source ?? {};
  const params = node.cloudResource?.params ?? {};
  const isEdge = "aws_cloudfront_behavior_" in connections || "aws_cloudfront_distribution" in connections;
  if (!isEdge)
    return false;
  params["publish"] = true;
  params["architectures"] = ["x86_64"];
  const roleKeys = connections["aws_iam_role"] ?? [];
  for (const roleKey of roleKeys) {
    const roleNode = self.nodeMap?.[roleKey];
    if (roleNode) {
      const roleParams = roleNode.cloudResource?.params ?? {};
      const assumePolicy = roleParams["assume_role_policy"] ?? "";
      if (!String(assumePolicy).includes("edgelambda.amazonaws.com")) {
        const oldService = '"Service": "lambda.amazonaws.com"';
        const newService = '"Service": ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]';
        if (String(assumePolicy).includes(oldService)) {
          roleParams["assume_role_policy"] = String(assumePolicy).replaceAll(oldService, newService);
        }
      }
    }
  }
  if ("environment_variables" in params)
    delete params["environment_variables"];
  return true;
}
__name(configureLambdaEdgeLogic, "configureLambdaEdgeLogic");
function injectLambdaEnvironmentVariables(lambdaParams, enrichedVars) {
  let existingVars = {};
  if ("environment" in lambdaParams) {
    const envVal = lambdaParams["environment"];
    if (Array.isArray(envVal) && envVal.length > 0) {
      const firstItem = envVal[0];
      if (firstItem && typeof firstItem === "object" && !Array.isArray(firstItem))
        existingVars = firstItem["variables"] || {};
    } else if (envVal && typeof envVal === "object" && !Array.isArray(envVal)) {
      existingVars = envVal["variables"] || {};
    }
  }
  if ((!enrichedVars || Object.keys(enrichedVars).length === 0) && Object.keys(existingVars).length === 0)
    return;
  const combined = { ...existingVars, ...enrichedVars || {} };
  const sanitized = {};
  for (const [key, val] of Object.entries(combined)) {
    const keyCleaned = String(key).trim().replace(/^['"]+|['"]+$/g, "").trim();
    if (!keyCleaned)
      continue;
    const valCleaned = String(val).trim().replace(/^['"]+|['"]+$/g, "").trim();
    sanitized[keyCleaned] = valCleaned;
  }
  lambdaParams["environment"] = { variables: sanitized };
}
__name(injectLambdaEnvironmentVariables, "injectLambdaEnvironmentVariables");
function applyLambdaPermissionDependency(triggerNode, permLogicalName) {
  if (!triggerNode)
    return;
  if (triggerNode.type === "aws_lambda_function")
    return;
  triggerNode.cloudResource ??= {};
  triggerNode.cloudResource.params ??= {};
  const triggerParams = triggerNode.cloudResource.params;
  let dependsOnList = triggerParams["depends_on"] ?? [];
  if (!Array.isArray(dependsOnList))
    dependsOnList = dependsOnList ? [dependsOnList] : [];
  const permissionRef = `aws_lambda_permission.${permLogicalName}`;
  if (!dependsOnList.includes(permissionRef))
    dependsOnList.push(permissionRef);
  triggerParams["depends_on"] = dependsOnList;
}
__name(applyLambdaPermissionDependency, "applyLambdaPermissionDependency");
function ensureLambdaPermission(self, lambdaNode, sourceNode, contextDetails = {}) {
  const lambdaLogicName = lambdaNode.logicalName;
  const sourceLogicName = sourceNode.logicalName;
  const sourceType = sourceNode.type;
  const principal = LAMBDA_PRINCIPAL_MAP[sourceType];
  if (!principal)
    return;
  let permLogicalName = `perm_${sourceType}_${sourceLogicName}_to_${lambdaLogicName}`;
  if ("method_node" in contextDetails) {
    const mName = contextDetails["method_node"].logicalName ?? "";
    permLogicalName += `_${mName}`;
  } else if ("openapi_node" in contextDetails) {
    permLogicalName += "_openapi";
  }
  const triggerNode = contextDetails["trigger_node"] ?? sourceNode;
  applyLambdaPermissionDependency(triggerNode, permLogicalName);
  for (const gn of self.generatedNodes) {
    if (gn.logicalName === permLogicalName)
      return;
  }
  let sourceArn = "";
  if (sourceType === "aws_api_gateway_rest_api") {
    const stagePart = "*";
    if ("openapi_node" in contextDetails) {
      const oaParams = contextDetails["openapi_node"].cloudResource?.params ?? {};
      const globalMethods = oaParams["http_methods"] || ["POST"];
      const methodPart = globalMethods.length === 1 ? String(globalMethods[0]).toUpperCase() : "*";
      const pathPart = lambdaLogicName;
      sourceArn = `\${aws_api_gateway_rest_api.${sourceLogicName}.execution_arn}/${stagePart}/${methodPart}/${pathPart}`;
    } else if ("method_node" in contextDetails) {
      const methodPart = contextDetails["method_node"].cloudResource?.params?.["http_method"] ?? "*";
      let resourcePartStr = "";
      if ("resource_node" in contextDetails) {
        const resLogical = contextDetails["resource_node"].logicalName;
        resourcePartStr = `aws_api_gateway_resource.${resLogical}.path`;
      }
      if (resourcePartStr) {
        sourceArn = `\${aws_api_gateway_rest_api.${sourceLogicName}.execution_arn}/${stagePart}/${methodPart}${resourcePartStr}`;
      } else {
        sourceArn = `\${aws_api_gateway_rest_api.${sourceLogicName}.execution_arn}/${stagePart}/${methodPart}/*`;
      }
    } else {
      sourceArn = `\${aws_api_gateway_rest_api.${sourceLogicName}.execution_arn}/*/*`;
    }
  } else if (sourceType in LAMBDA_PRINCIPAL_MAP) {
    sourceArn = `${sourceType}.${sourceLogicName}.arn`;
  }
  const newPermNode = self.addGenericNode(self.generatedNodes, "aws_lambda_permission", permLogicalName, sourceNode, lambdaNode);
  if (newPermNode) {
    if (newPermNode.terraformID === lambdaNode.terraformID)
      newPermNode["group"] = lambdaNode["group"];
    else if (newPermNode.terraformID === sourceNode.terraformID)
      newPermNode["group"] = sourceNode["group"];
    const params = newPermNode.cloudResource.params;
    params["action"] = "lambda:InvokeFunction";
    params["function_name"] = `aws_lambda_function.${lambdaLogicName}.function_name`;
    params["principal"] = principal;
    params["statement_id"] = self.hcl.ensureParamLimit(permLogicalName, 100);
    if (sourceArn)
      params["source_arn"] = sourceArn;
    newPermNode.connections = newPermNode.connections ?? { source: {}, target: {} };
    newPermNode.connections.target = { aws_lambda_function: [lambdaNode.key] };
    newPermNode.connections.source = { [sourceType]: [sourceNode.key] };
  }
}
__name(ensureLambdaPermission, "ensureLambdaPermission");
function processLambdaVpcConfig(self) {
  const node = self.node;
  const subnetKeys = node.connections?.target?.["aws_subnet"] ?? [];
  const sgKeys = node.connections?.source?.["aws_security_group"] ?? [];
  const nodeId = node.key;
  const subnetIds = [];
  for (const key of subnetKeys) {
    const sNode = self.nodeMap?.[key];
    if (sNode)
      subnetIds.push(`aws_subnet.${sNode.logicalName}.id`);
  }
  const sgIds = [];
  for (const key of sgKeys) {
    const sgNode = self.nodeMap?.[key];
    if (sgNode)
      sgIds.push(`aws_security_group.${sgNode.logicalName}.id`);
  }
  if (subnetKeys.length > 0 && sgIds.length === 0) {
    self.collector.addError(["lambda_missing_sg", nodeId]);
    return;
  }
  if (subnetKeys.length > 0) {
    const vpcConfigBlock = { subnet_ids: subnetIds, security_group_ids: sgIds };
    const vpcKeys = node.connections?.target?.["aws_vpc"] ?? [];
    if (vpcKeys.length > 0) {
      const vpcNode = self.nodeMap?.[vpcKeys[0]];
      if (vpcNode && vpcNode["has_ipv6"] === true)
        vpcConfigBlock["ipv6_allowed_for_dual_stack"] = true;
    }
    node.cloudResource.params["vpc_config"] = [vpcConfigBlock];
    const statement = [
      {
        Effect: "Allow",
        Action: [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ],
        Resource: "*"
      }
    ];
    self.createDynamicPolicy(node, "VPCAccess", statement);
  }
}
__name(processLambdaVpcConfig, "processLambdaVpcConfig");
function handleAwsLambdaFunction(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  ensureLambdaHandler(node);
  processGithubArchive(self, node);
  let interpolatedLayers = params["layers"] || [];
  let staticLayers = params["layers_"] || [];
  if (!Array.isArray(interpolatedLayers))
    interpolatedLayers = [interpolatedLayers];
  if (!Array.isArray(staticLayers))
    staticLayers = [staticLayers];
  if (staticLayers.length > 0)
    params["layers"] = [...interpolatedLayers, ...staticLayers];
  const isLambdaEdge = configureLambdaEdgeLogic(self, node);
  if (!isLambdaEdge) {
    const enrichedVariables = self.processPayloadEnvVars(node);
    injectLambdaEnvironmentVariables(params, enrichedVariables);
  }
  processLambdaVpcConfig(self);
  const PERMISSION_TRIGGERS = [...Object.keys(LAMBDA_PRINCIPAL_MAP), "cldmn_open_api", "aws_api_gateway_integration", "aws_s3_bucket_notification", "aws_cloudwatch_event_target"];
  const connections = node.connections?.source ?? {};
  for (const [srcResType, srcKeys] of Object.entries(connections)) {
    if (!PERMISSION_TRIGGERS.includes(srcResType))
      continue;
    for (const srcKey of srcKeys) {
      const sourceNode = self.nodeMap?.[srcKey];
      if (!sourceNode)
        continue;
      let resolvedSourceNode = sourceNode;
      const contextDetails = { trigger_node: sourceNode };
      if (srcResType === "cldmn_open_api") {
        contextDetails["openapi_node"] = sourceNode;
        const gatewayKeys = sourceNode.connections?.source?.["aws_api_gateway_rest_api"] ?? [];
        if (gatewayKeys.length > 0) {
          const realApi = self.nodeMap?.[gatewayKeys[0]];
          if (realApi)
            resolvedSourceNode = realApi;
        }
      } else if (srcResType === "aws_api_gateway_integration") {
        const methodKeys = sourceNode.connections?.source?.["aws_api_gateway_method"] ?? [];
        if (methodKeys.length > 0) {
          const methodNode = self.nodeMap?.[methodKeys[0]];
          if (methodNode) {
            contextDetails["method_node"] = methodNode;
            const resKeys = methodNode.connections?.source?.["aws_api_gateway_resource"] ?? [];
            if (resKeys.length > 0) {
              const resourceNode = self.nodeMap?.[resKeys[0]];
              if (resourceNode) {
                contextDetails["resource_node"] = resourceNode;
                const apiKeys = resourceNode.connections?.source?.["aws_api_gateway_rest_api"] ?? [];
                if (apiKeys.length > 0) {
                  const realApi = self.nodeMap?.[apiKeys[0]];
                  if (realApi)
                    resolvedSourceNode = realApi;
                }
              }
            }
          }
        }
      } else if (srcResType === "aws_s3_bucket_notification") {
        const bucketKeys = sourceNode.connections?.source?.["aws_s3_bucket"] ?? [];
        if (bucketKeys.length > 0) {
          const bucketNode = self.nodeMap?.[bucketKeys[0]];
          if (bucketNode)
            resolvedSourceNode = bucketNode;
        }
      } else if (srcResType === "aws_cloudwatch_event_target") {
        const ruleKeys = sourceNode.connections?.source?.["aws_cloudwatch_event_rule"] ?? [];
        if (ruleKeys.length > 0) {
          const ruleNode = self.nodeMap?.[ruleKeys[0]];
          if (ruleNode)
            resolvedSourceNode = ruleNode;
        }
      }
      ensureLambdaPermission(self, node, resolvedSourceNode, contextDetails);
    }
  }
}
__name(handleAwsLambdaFunction, "handleAwsLambdaFunction");
function handleAwsLambdaLayerVersion(self) {
  const node = self.node;
  const connections = node.connections?.source ?? {};
  const githubKeys = connections["cldmn_github"] ?? [];
  if (githubKeys.length === 0)
    return;
  const githubNode = self.nodeMap?.[githubKeys[0]];
  if (!githubNode)
    return;
  const ghParams = githubNode.cloudResource?.params ?? {};
  const githubRepo = ghParams["github_repository"] ?? "";
  const layerUi = node.cloudResource?.params ?? {};
  const filePath = normalizePath(String(layerUi["file_path_"] ?? ""));
  const params = node.cloudResource?.params ?? {};
  const rawPath = `\${path.module}/.external_modules/${githubRepo}/${filePath}`;
  const fullSourcePath = normalizePath(rawPath);
  params["filename"] = fullSourcePath;
  params["source_code_hash"] = `\${filebase64sha256("${fullSourcePath}")}`;
}
__name(handleAwsLambdaLayerVersion, "handleAwsLambdaLayerVersion");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_instance() {
    return handleAwsInstance(this);
  },
  handle_aws_launch_template() {
    return handleAwsLaunchTemplate(this);
  },
  handle_aws_lambda_function() {
    return handleAwsLambdaFunction(this);
  },
  handle_aws_lambda_layer_version() {
    return handleAwsLambdaLayerVersion(this);
  }
});

// src/handlers/ecs.ts
function isEmptyValue2(v) {
  return v === null || v === void 0 || v === "" || Array.isArray(v) && v.length === 0 || typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 0;
}
__name(isEmptyValue2, "isEmptyValue");
function getConnectedLogGroup(self, node) {
  const cwKeys = node.connections?.target?.["aws_cloudwatch_log_group"] ?? [];
  if (cwKeys.length > 0) {
    const cwNode = self.nodeMap?.[cwKeys[0]];
    if (cwNode)
      return { logical_name: cwNode.logicalName };
  }
  return null;
}
__name(getConnectedLogGroup, "getConnectedLogGroup");
function applyEcsTaskLogConfiguration(containerDef, logGroupInfo) {
  const containerName = containerDef["name"] ?? "ecs";
  const logGroupRef = `aws_cloudwatch_log_group.${logGroupInfo.logical_name}.name`;
  containerDef["logConfiguration"] = {
    logDriver: "awslogs",
    options: { "awslogs-group": logGroupRef, "awslogs-region": "us-east-1", "awslogs-stream-prefix": containerName }
  };
  return containerDef;
}
__name(applyEcsTaskLogConfiguration, "applyEcsTaskLogConfiguration");
function processTaskDefinitionEfsVolumes(self, taskNode, containerNodes) {
  const taskParams = taskNode.cloudResource?.params ?? {};
  if (!("volume" in taskParams))
    taskParams["volume"] = [];
  const processedVolumes = /* @__PURE__ */ new Set();
  for (const cNode of containerNodes) {
    const apKeys = cNode.connections?.target?.["aws_efs_access_point"] ?? [];
    if (apKeys.length === 0)
      continue;
    const cParams = cNode.cloudResource?.params ?? {};
    const mountPoints = cParams["mountPoints"] ?? [];
    for (const apKey of apKeys) {
      const apNode = self.nodeMap?.[apKey];
      if (!apNode)
        continue;
      const apLogicalName = apNode.logicalName ?? "efs_ap";
      const volumeName = `aws_efs_access_point_${apLogicalName}`;
      if (Array.isArray(mountPoints)) {
        for (const mp of mountPoints) {
          if (!mp["sourceVolume"]) {
            mp["sourceVolume"] = volumeName;
            break;
          }
        }
      }
      if (!processedVolumes.has(volumeName)) {
        processedVolumes.add(volumeName);
        let efsIdRef = "";
        const efsKeys = apNode.connections?.target?.["aws_efs_file_system"] ?? [];
        if (efsKeys.length > 0) {
          const efsNode = self.nodeMap?.[efsKeys[0]];
          if (efsNode)
            efsIdRef = `\${aws_efs_file_system.${efsNode.logicalName}.id}`;
        }
        if (!efsIdRef)
          efsIdRef = `\${aws_efs_access_point.${apLogicalName}.file_system_id}`;
        const apIdRef = `\${aws_efs_access_point.${apLogicalName}.id}`;
        taskParams["volume"].push({
          name: volumeName,
          efs_volume_configuration: [
            {
              file_system_id: efsIdRef,
              transit_encryption: "ENABLED",
              authorization_config: [{ access_point_id: apIdRef, iam: "ENABLED" }]
            }
          ]
        });
      }
    }
  }
}
__name(processTaskDefinitionEfsVolumes, "processTaskDefinitionEfsVolumes");
function buildSingleContainerData(self, containerNode, taskNode) {
  const cParams = containerNode.cloudResource?.params ?? {};
  const imageName = cParams["image"] ?? "";
  let finalImage = imageName;
  let ecrRepoNode = null;
  const connections = containerNode.connections ?? {};
  for (const connType of ["source", "target"]) {
    if ("aws_ecr_repository" in (connections[connType] ?? {})) {
      const ecrId = connections[connType]["aws_ecr_repository"][0];
      ecrRepoNode = self.nodeMap?.[ecrId] ?? null;
      break;
    }
  }
  if (ecrRepoNode) {
    const separator = String(imageName).startsWith(":") ? "" : ":";
    finalImage = `\${aws_ecr_repository.${ecrRepoNode.logicalName}.repository_url}${separator}${imageName}`;
  } else {
    let imageProvider = cParams["image_provider"] ?? "";
    if (imageProvider) {
      if (!String(imageProvider).endsWith("/"))
        imageProvider += "/";
      finalImage = `${imageProvider}${imageName}`;
    } else {
      finalImage = imageName;
    }
  }
  const containerDef = {
    name: cParams["name"] ?? null,
    image: finalImage,
    essential: cParams["essential"] ?? true
  };
  for (const intField of ["cpu", "memory", "memoryReservation", "startTimeout", "stopTimeout"]) {
    if (cParams[intField]) {
      const n = parseInt(String(cParams[intField]), 10);
      if (!Number.isNaN(n))
        containerDef[intField] = n;
    }
  }
  if (cParams["portMappings"]) {
    const mappedPorts = [];
    for (const pm of cParams["portMappings"]) {
      const entry = { protocol: pm["protocol"] ?? "tcp" };
      if (pm["containerPort"])
        entry["containerPort"] = parseInt(String(pm["containerPort"]), 10);
      if (pm["hostPort"])
        entry["hostPort"] = parseInt(String(pm["hostPort"]), 10);
      mappedPorts.push(entry);
    }
    containerDef["portMappings"] = mappedPorts;
  }
  const processedVars = self.processPayloadEnvVars(taskNode);
  const containerLogicalName = containerNode.logicalName ?? "";
  const envList = [];
  const extractedDbSecrets = [];
  const dbSecretSubstrings = ["AWS_DB_INSTANCE_PASS"];
  const processAndRouteVar = /* @__PURE__ */ __name((varName, varValue) => {
    const vName = String(varName);
    let vVal = varValue !== null && varValue !== void 0 ? String(varValue) : "";
    const isDbSecret = dbSecretSubstrings.some((sub) => vName.includes(sub));
    if (isDbSecret) {
      extractedDbSecrets.push({ name: vName, valueFrom: vVal });
    } else {
      if (vName === "NAME")
        vVal = containerLogicalName;
      envList.push({ name: vName, value: vVal });
    }
  }, "processAndRouteVar");
  for (const [k, v] of Object.entries(processedVars))
    processAndRouteVar(k, v);
  const blockEnv = cParams["environment"] ?? [];
  if (Array.isArray(blockEnv)) {
    for (const item of blockEnv)
      processAndRouteVar(item["name"] ?? "", item["value"] ?? "");
  }
  if (envList.length > 0)
    containerDef["environment"] = envList;
  const computedSecrets = [];
  const secretTypesToCheck = ["aws_secretsmanager_secret", "aws_ssm_parameter"];
  const connData = connections.source ?? {};
  for (const resType of secretTypesToCheck) {
    if (resType in connData) {
      for (const nodeId of connData[resType]) {
        const secretNode = self.nodeMap?.[nodeId];
        if (!secretNode)
          continue;
        const sLogicalName = secretNode.logicalName;
        if (!sLogicalName)
          continue;
        const valueFrom = resType === "aws_secretsmanager_secret" ? `\${aws_secretsmanager_secret.${sLogicalName}.arn}` : `\${aws_ssm_parameter.${sLogicalName}.arn}`;
        computedSecrets.push({ name: String(sLogicalName).toUpperCase(), valueFrom });
      }
    }
  }
  const manualSecrets = cParams["secrets"] ?? [];
  if (Array.isArray(manualSecrets) && manualSecrets.length > 0)
    computedSecrets.push(...manualSecrets);
  if (extractedDbSecrets.length > 0)
    computedSecrets.push(...extractedDbSecrets);
  if (computedSecrets.length > 0)
    containerDef["secrets"] = computedSecrets;
  const computedEnvFiles = [];
  if ("aws_s3_bucket" in connData) {
    for (const bucketId of connData["aws_s3_bucket"]) {
      const bucketNode = self.nodeMap?.[bucketId];
      if (!bucketNode)
        continue;
      const bucketLogicalName = bucketNode.logicalName;
      if (!bucketLogicalName)
        continue;
      const s3FileArn = `\${aws_s3_bucket.${bucketLogicalName}.arn}/config.txt`;
      computedEnvFiles.push({ value: s3FileArn, type: "s3" });
    }
  }
  const manualEnvFiles = cParams["environmentFiles"] ?? [];
  if (Array.isArray(manualEnvFiles) && manualEnvFiles.length > 0)
    computedEnvFiles.push(...manualEnvFiles);
  if (computedEnvFiles.length > 0)
    containerDef["environmentFiles"] = computedEnvFiles;
  const directFields = ["logConfiguration", "mountPoints", "command", "entryPoint", "workingDirectory", "linuxParameters", "user", "privileged", "readonlyRootFilesystem"];
  for (const field of directFields) {
    const val = cParams[field];
    if (!isEmptyValue2(val)) {
      if (field === "entryPoint" && Array.isArray(val)) {
        const processedEntrypoint = val.map((item) => typeof item === "string" && !item.startsWith("<<") ? `__RAW__${item}` : item);
        containerDef[field] = processedEntrypoint;
      } else {
        containerDef[field] = val;
      }
    }
  }
  return containerDef;
}
__name(buildSingleContainerData, "buildSingleContainerData");
function ensureTaskDefinitionConnection(node, direction, typeKey, targetKey) {
  const n = node;
  if (!("connections" in n) || !n["connections"])
    n["connections"] = {};
  if (!(direction in n["connections"]))
    n["connections"][direction] = {};
  if (!(typeKey in n["connections"][direction]))
    n["connections"][direction][typeKey] = [];
  if (!n["connections"][direction][typeKey].includes(targetKey))
    n["connections"][direction][typeKey].push(targetKey);
}
__name(ensureTaskDefinitionConnection, "ensureTaskDefinitionConnection");
function removeTaskDefinitionConnection(node, direction, typeKey, targetKey) {
  const arr = node.connections?.[direction]?.[typeKey];
  if (arr && arr.includes(targetKey))
    arr.splice(arr.indexOf(targetKey), 1);
}
__name(removeTaskDefinitionConnection, "removeTaskDefinitionConnection");
function discoverAndLinkTaskDefinitionContainerPolicies(self, taskNode, finalRoleRef) {
  const taskKey = taskNode.key;
  const containerKeys = taskNode.connections?.source?.["aws_ecs_container_"] ?? [];
  if (containerKeys.length === 0)
    return;
  const targetResourceTypes = ["aws_secretsmanager_secret", "aws_ssm_parameter", "aws_ecr_repository", "aws_s3_bucket"];
  for (const contKey of containerKeys) {
    const containerNode = self.nodeMap?.[contKey];
    if (!containerNode)
      continue;
    const contSources = containerNode.connections?.source ?? {};
    for (const resType of targetResourceTypes) {
      const resourceKeys = contSources[resType] ?? [];
      for (const resKey of resourceKeys) {
        const resourceNode = self.nodeMap?.[resKey];
        if (!resourceNode)
          continue;
        const policyKeys = [...resourceNode.connections?.target?.["cldmn_policy"] ?? []];
        for (const policyKey of policyKeys) {
          const policyNode = self.nodeMap?.[policyKey];
          if (!policyNode)
            continue;
          ensureTaskDefinitionConnection(taskNode, "target", "cldmn_policy", policyKey);
          ensureTaskDefinitionConnection(policyNode, "source", "aws_ecs_task_definition", taskKey);
          removeTaskDefinitionConnection(resourceNode, "target", "cldmn_policy", policyKey);
          removeTaskDefinitionConnection(policyNode, "source", resType, resKey);
          ensureTaskDefinitionConnection(policyNode, "target", resType, resKey);
          ensureTaskDefinitionConnection(resourceNode, "source", "cldmn_policy", policyKey);
          const pn = policyNode;
          if (!("_internal_metadata" in pn))
            pn["_internal_metadata"] = {};
          pn["_internal_metadata"]["forced_role_ref"] = finalRoleRef;
        }
      }
    }
  }
}
__name(discoverAndLinkTaskDefinitionContainerPolicies, "discoverAndLinkTaskDefinitionContainerPolicies");
function processTaskDefinitionRoles(self, node, params) {
  const iamRoleKeys = node.connections?.source?.["aws_iam_role"] ?? [];
  let executionRoleNode = null;
  for (const roleKey of iamRoleKeys) {
    const roleNode = self.nodeMap?.[roleKey];
    if (!roleNode)
      continue;
    const rn = roleNode;
    if (!("_internal_metadata" in rn))
      rn["_internal_metadata"] = {};
    const roleLogicalName = String(roleNode.logicalName ?? "").toLowerCase();
    const tfReference = `aws_iam_role.${roleNode.logicalName}.arn`;
    if (roleLogicalName.includes("execution")) {
      params["execution_role_arn"] = tfReference;
      rn["_internal_metadata"]["role_index"] = 1;
      executionRoleNode = roleNode;
    } else if (roleLogicalName.includes("task")) {
      params["task_role_arn"] = tfReference;
      rn["_internal_metadata"]["role_index"] = 0;
    }
  }
  let finalRoleRef;
  if (executionRoleNode) {
    const execRoleNameParam = executionRoleNode.cloudResource?.params?.["name"];
    finalRoleRef = execRoleNameParam ? String(execRoleNameParam) : `aws_iam_role.${executionRoleNode.logicalName}.name`;
    const logGroupKeys = node.connections?.target?.["aws_cloudwatch_log_group"] ?? [];
    for (const lgKey of logGroupKeys) {
      const lgNode = self.nodeMap?.[lgKey];
      if (!lgNode)
        continue;
      const policyKeys = lgNode.connections?.source?.["cldmn_policy"] ?? [];
      for (const policyKey of policyKeys) {
        const policyNode = self.nodeMap?.[policyKey];
        if (policyNode) {
          const pn = policyNode;
          if (!("_internal_metadata" in pn))
            pn["_internal_metadata"] = {};
          pn["_internal_metadata"]["forced_role_ref"] = finalRoleRef;
        }
      }
      break;
    }
  }
  if (finalRoleRef === void 0)
    throw new Error("name 'final_role_ref' is not defined");
  discoverAndLinkTaskDefinitionContainerPolicies(self, node, finalRoleRef);
}
__name(processTaskDefinitionRoles, "processTaskDefinitionRoles");
function ecsTaskGeneralConfig(taskNode, params) {
  let compatibility = "FARGATE";
  const connections = taskNode.connections ?? {};
  const hasAsg = "aws_autoscaling_group" in (connections.target ?? {});
  if (hasAsg)
    compatibility = "EC2";
  else
    params["network_mode"] = "awsvpc";
  params["requires_compatibilities"] = [compatibility];
}
__name(ecsTaskGeneralConfig, "ecsTaskGeneralConfig");
function handlePreAwsEcsTaskDefinition(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  self.hcl.ignoredTypes.add("aws_ecs_container_");
  const logGroupInfo = getConnectedLogGroup(self, node);
  const containerNodes = [];
  const containerKeys = node.connections?.source?.["aws_ecs_container_"] ?? [];
  for (const k of containerKeys) {
    const cNode = self.nodeMap?.[k];
    if (cNode)
      containerNodes.push(cNode);
  }
  processTaskDefinitionEfsVolumes(self, node, containerNodes);
  if (!("_embedded_locals" in node))
    node["_embedded_locals"] = {};
  const localReferences = [];
  const taskLogicalName = node.logicalName ?? "task";
  for (const cNode of containerNodes) {
    let cData = buildSingleContainerData(self, cNode, node);
    if (logGroupInfo)
      cData = applyEcsTaskLogConfiguration(cData, logGroupInfo);
    const cLogicalName = cNode.logicalName ?? "unknown";
    const localVarName = `container_def_${taskLogicalName}_${cLogicalName}`;
    node["_embedded_locals"][localVarName] = cData;
    localReferences.push(`local.${localVarName}`);
  }
  params["container_definitions"] = `__RAW__jsonencode([${localReferences.join(", ")}])`;
  processTaskDefinitionRoles(self, node, params);
  ecsTaskGeneralConfig(node, params);
}
__name(handlePreAwsEcsTaskDefinition, "handlePreAwsEcsTaskDefinition");
function configureLoadBalancerSettings(self, params, targetConns) {
  const lbConfigs = [];
  const taskDefKeys = targetConns["aws_ecs_task_definition"] ?? [];
  if (taskDefKeys.length === 0)
    return;
  const taskDefNode = self.nodeMap?.[taskDefKeys[0]];
  if (!taskDefNode)
    return;
  const containerKeys = taskDefNode.connections?.source?.["aws_ecs_container_"] ?? [];
  for (const contKey of containerKeys) {
    const containerNode = self.nodeMap?.[contKey];
    if (!containerNode)
      continue;
    const tgKeys = containerNode.connections?.source?.["aws_lb_target_group"] ?? [];
    if (tgKeys.length > 0) {
      const contParams = containerNode.cloudResource?.params ?? {};
      const containerName = contParams["name"];
      const portMappings = contParams["portMappings"] ?? [];
      let containerPort = null;
      if (Array.isArray(portMappings) && portMappings.length > 0)
        containerPort = portMappings[0]["containerPort"];
      if (containerName && containerPort) {
        for (const tgKey of tgKeys) {
          const tgNode = self.nodeMap?.[tgKey];
          if (tgNode) {
            lbConfigs.push({
              target_group_arn: `aws_lb_target_group.${tgNode.logicalName}.arn`,
              container_name: containerName,
              container_port: containerPort
            });
          }
        }
      }
    }
  }
  if (lbConfigs.length > 0)
    params["load_balancer"] = lbConfigs;
}
__name(configureLoadBalancerSettings, "configureLoadBalancerSettings");
function resolveServiceDependencies(self, targetConns, sourceConns) {
  const tfSubnetRefs = [];
  const tfSgRefs = [];
  const logicSubnetKeys = [];
  let launchType = "EC2";
  const directSubnetKeys = targetConns["aws_subnet"] ?? [];
  const directSgKeys = sourceConns["aws_security_group"] ?? [];
  if (directSubnetKeys.length > 0) {
    launchType = "FARGATE";
    for (const key of directSubnetKeys) {
      const sNode = self.nodeMap?.[key];
      if (sNode) {
        logicSubnetKeys.push(key);
        tfSubnetRefs.push(`aws_subnet.${sNode.logicalName}.id`);
      }
    }
    for (const key of directSgKeys) {
      const sgNode = self.nodeMap?.[key];
      if (sgNode)
        tfSgRefs.push(`aws_security_group.${sgNode.logicalName}.id`);
    }
  } else {
    const asgKeys = targetConns["aws_autoscaling_group"] ?? [];
    if (asgKeys.length > 0) {
      launchType = "EC2";
      for (const asgKey of asgKeys) {
        const asgNode = self.nodeMap?.[asgKey];
        if (asgNode) {
          const asgSubnetKeys = asgNode.connections?.target?.["aws_subnet"] ?? [];
          for (const key of asgSubnetKeys) {
            const sNode = self.nodeMap?.[key];
            if (sNode) {
              logicSubnetKeys.push(key);
              tfSubnetRefs.push(`aws_subnet.${sNode.logicalName}.id`);
            }
          }
          const asgSgKeys = asgNode.connections?.source?.["aws_security_group"] ?? [];
          for (const key of asgSgKeys) {
            const sgNode = self.nodeMap?.[key];
            if (sgNode)
              tfSgRefs.push(`aws_security_group.${sgNode.logicalName}.id`);
          }
        }
      }
    }
  }
  return { tfSubnetRefs, tfSgRefs, logicSubnetKeys, launchType };
}
__name(resolveServiceDependencies, "resolveServiceDependencies");
function configureComputeStrategy(self, params, targetConns, launchType) {
  if (launchType === "EC2") {
    params["launch_type"] = "";
    const cpKeys = targetConns["aws_ecs_capacity_provider"] ?? [];
    if (cpKeys.length > 0) {
      const cpStrategies = [];
      for (const cpKey of cpKeys) {
        const cpNode = self.nodeMap?.[cpKey];
        if (cpNode)
          cpStrategies.push({ capacity_provider: `aws_ecs_capacity_provider.${cpNode.logicalName}.name`, weight: 1, base: 0 });
      }
      params["capacity_provider_strategy"] = cpStrategies;
    }
  } else {
    params["launch_type"] = "FARGATE";
  }
}
__name(configureComputeStrategy, "configureComputeStrategy");
function configureNetworkSettings(self, params, targetConns, tfSubnetRefs, tfSgRefs, logicSubnetKeys, launchType) {
  const taskDefKeys = targetConns["aws_ecs_task_definition"] ?? [];
  let isAwsvpc = launchType === "FARGATE";
  if (!isAwsvpc && taskDefKeys.length > 0) {
    const tdNode = self.nodeMap?.[taskDefKeys[0]];
    if (tdNode && tdNode.cloudResource?.params?.["network_mode"] === "awsvpc")
      isAwsvpc = true;
  }
  if (tfSubnetRefs.length > 0 && isAwsvpc) {
    if (!("network_configuration" in params) || !params["network_configuration"])
      params["network_configuration"] = [{}];
    const netConfig = Array.isArray(params["network_configuration"]) ? params["network_configuration"][0] : params["network_configuration"];
    if (launchType === "FARGATE") {
      let publicCount = 0;
      for (const sKey of logicSubnetKeys) {
        const subnetNode = self.nodeMap?.[sKey];
        if (subnetNode && subnetNode["is_public"] === true)
          publicCount += 1;
      }
      netConfig["assign_public_ip"] = publicCount > 0;
    } else {
      netConfig["assign_public_ip"] = false;
    }
    netConfig["subnets"] = [...new Set(tfSubnetRefs)];
    if (tfSgRefs.length > 0)
      netConfig["security_groups"] = [...new Set(tfSgRefs)];
  }
}
__name(configureNetworkSettings, "configureNetworkSettings");
function handleAwsEcsService(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const targetConns = node.connections?.target ?? {};
  const sourceConns = node.connections?.source ?? {};
  const { tfSubnetRefs, tfSgRefs, logicSubnetKeys, launchType } = resolveServiceDependencies(self, targetConns, sourceConns);
  configureComputeStrategy(self, params, targetConns, launchType);
  configureNetworkSettings(self, params, targetConns, tfSubnetRefs, tfSgRefs, logicSubnetKeys, launchType);
  configureLoadBalancerSettings(self, params, targetConns);
}
__name(handleAwsEcsService, "handleAwsEcsService");
function generateSimpleDestroyScript(clusterName, region) {
  return `
        # ECS Resource Cleanup to prevent Auto Scaling Group (ASG) Deadlock
        # ------------------------------------------------------------------
        # EXPLANATION:
        # When destroying an ECS Cluster backed by an ASG with Capacity Providers,
        # a deadlock often occurs. The ASG cannot terminate EC2 instances because
        # ECS "Instance Protection" prevents scale-in while tasks are running.
        # However, Terraform may try to delete the ASG before the ECS services
        # have fully drained.
        #
        # This script acts as a safeguard to proactively force-drain services,
        # stop tasks, and deregister instances. This ensures the ASG is free
        # to scale down and allows the infrastructure destruction to proceed
        # without hanging.
        # ------------------------------------------------------------------
        # Uses environment credentials (OIDC/GitHub Actions)

        # Wait briefly to ensure Terraform has initiated the destruction process
        sleep 30

        # List and scale down services
        SERVICES=$(aws ecs list-services --cluster ${clusterName} --region ${region} --query "serviceArns[*]" --output text)
        if [ -n "$SERVICES" ] && [ "$SERVICES" != "None" ]; then
            for SERVICE in $SERVICES; do
                echo "Scaling down service: $SERVICE"
                aws ecs update-service --cluster ${clusterName} --region ${region} --service "$SERVICE" --desired-count 0 > /dev/null
            done
            sleep 10
            for SERVICE in $SERVICES; do
                echo "Deleting service: $SERVICE"
                aws ecs delete-service --cluster ${clusterName} --region ${region} --service "$SERVICE" --force > /dev/null
            done
        fi

        # Stop remaining tasks
        TASKS=$(aws ecs list-tasks --cluster ${clusterName} --region ${region} --query "taskArns[*]" --output text)
        if [ -n "$TASKS" ] && [ "$TASKS" != "None" ]; then
            for TASK in $TASKS; do
                echo "Stopping task: $TASK"
                aws ecs stop-task --cluster ${clusterName} --region ${region} --task "$TASK" > /dev/null
            done
        fi

        # Deregister container instances (EC2)
        INSTANCE_ARNS=$(aws ecs list-container-instances --cluster ${clusterName} --region ${region} --query "containerInstanceArns[*]" --output text)
        if [ -n "$INSTANCE_ARNS" ] && [ "$INSTANCE_ARNS" != "None" ]; then
            for INSTANCE_ARN in $INSTANCE_ARNS; do
                echo "Deregistering instance: $INSTANCE_ARN"
                aws ecs deregister-container-instance --cluster ${clusterName} --region ${region} --container-instance "$INSTANCE_ARN" --force > /dev/null
            done
        fi
        `;
}
__name(generateSimpleDestroyScript, "generateSimpleDestroyScript");
function ensureAsgEcsPermissions(self, asgNode, clusterLogicalName) {
  if (!asgNode)
    return;
  const clusterArnRef = `\${aws_ecs_cluster.${clusterLogicalName}.arn}`;
  const statement = [
    {
      Effect: "Allow",
      Action: ["ecs:RegisterContainerInstance", "ecs:DeregisterContainerInstance", "ecs:DiscoverPollEndpoint", "ecs:Submit*", "ecs:Poll", "ecs:StartTelemetrySession"],
      Resource: [clusterArnRef]
    }
  ];
  self.createDynamicPolicy(asgNode, "ECSAccess", statement);
  self.addManagedPolicy(asgNode, "service-role/AmazonEC2ContainerServiceforEC2Role", self.nodeMap ?? {});
  const [, regionRaw] = findAccountAndRegionName(asgNode, self.nodeMap ?? {});
  const region = regionRaw || "us-east-1";
  const clusterRealRef = `\${aws_ecs_cluster.${clusterLogicalName}.name}`;
  const clusterNameForScript = "${self.triggers.cluster_name}";
  const scriptContent = generateSimpleDestroyScript(clusterNameForScript, region);
  const cleanupNode = self.addGenericNode(self.generatedNodes, "null_resource", `cleanup_${clusterLogicalName}`, asgNode, null);
  if (cleanupNode) {
    cleanupNode.cloudResource.params = { triggers: { cluster_name: clusterRealRef } };
    cleanupNode.cloudResource["provisioners"] = [
      { type: "local-exec", when: "destroy", command: scriptContent, interpreter: ["/bin/bash", "-c"] }
    ];
    const p = cleanupNode.cloudResource.params;
    if (!("depends_on" in p))
      p["depends_on"] = [];
    p["depends_on"].push(`aws_ecs_cluster.${clusterLogicalName}`);
  }
}
__name(ensureAsgEcsPermissions, "ensureAsgEcsPermissions");
function handleAwsEcsCluster(self) {
  const node = self.node;
  const clusterLogicalName = node.logicalName;
  const clusterKey = node.key;
  const serviceKeys = node.connections?.source?.["aws_ecs_service"] ?? [];
  const uniqueCpKeys = /* @__PURE__ */ new Set();
  for (const sKey of serviceKeys) {
    const serviceNode = self.nodeMap?.[sKey];
    if (!serviceNode)
      continue;
    const cpKeysInService = serviceNode.connections?.target?.["aws_ecs_capacity_provider"] ?? [];
    for (const cpKey of cpKeysInService)
      uniqueCpKeys.add(cpKey);
  }
  if (uniqueCpKeys.size > 0) {
    const cpRefs = [];
    const cpNodes = [];
    const processedAsgKeys = /* @__PURE__ */ new Set();
    for (const cpKey of uniqueCpKeys) {
      const cpNode = self.nodeMap?.[cpKey];
      if (cpNode) {
        cpNodes.push(cpNode);
        cpRefs.push(`aws_ecs_capacity_provider.${cpNode.logicalName}.name`);
        const asgKeys = cpNode.connections?.target?.["aws_autoscaling_group"] ?? [];
        for (const asgKey of asgKeys) {
          if (!processedAsgKeys.has(asgKey)) {
            const asgNode = self.nodeMap?.[asgKey] ?? null;
            ensureAsgEcsPermissions(self, asgNode, clusterLogicalName);
            processedAsgKeys.add(asgKey);
          }
        }
      }
    }
    cpRefs.sort();
    const assocLogicalName = `assoc_cp_to_${clusterLogicalName}`;
    const newAssocNode = self.addGenericNode(self.generatedNodes, "aws_ecs_cluster_capacity_providers", assocLogicalName, node, null);
    if (newAssocNode) {
      if (node.terraformID)
        newAssocNode.terraformID = node.terraformID;
      newAssocNode["group"] = node["group"];
      newAssocNode.cloudResource.params = {
        cluster_name: `aws_ecs_cluster.${clusterLogicalName}.name`,
        capacity_providers: cpRefs,
        default_capacity_provider_strategy: []
      };
      newAssocNode.connections = { source: { aws_ecs_cluster: [clusterKey] }, target: { aws_ecs_capacity_provider: cpNodes.map((cp) => cp.key) } };
    }
  }
}
__name(handleAwsEcsCluster, "handleAwsEcsCluster");
Object.assign(AwsProviderLogic.prototype, {
  handle_pre_aws_ecs_task_definition() {
    return handlePreAwsEcsTaskDefinition(this);
  },
  handle_aws_ecs_service() {
    return handleAwsEcsService(this);
  },
  handle_aws_ecs_cluster() {
    return handleAwsEcsCluster(this);
  }
});

// src/handlers/apigateway.ts
function pyJsonStr(s) {
  let out = '"';
  for (const ch of s) {
    const code = ch.codePointAt(0);
    if (ch === '"')
      out += '\\"';
    else if (ch === "\\")
      out += "\\\\";
    else if (ch === "\n")
      out += "\\n";
    else if (ch === "\r")
      out += "\\r";
    else if (ch === "	")
      out += "\\t";
    else if (ch === "\b")
      out += "\\b";
    else if (ch === "\f")
      out += "\\f";
    else if (code < 32 || code > 126) {
      if (code > 65535) {
        const c = code - 65536;
        out += "\\u" + (55296 + (c >> 10)).toString(16).padStart(4, "0") + "\\u" + (56320 + (c & 1023)).toString(16).padStart(4, "0");
      } else
        out += "\\u" + code.toString(16).padStart(4, "0");
    } else
      out += ch;
  }
  return out + '"';
}
__name(pyJsonStr, "pyJsonStr");
function jsonDumpsDefault(value) {
  if (value === null || value === void 0)
    return "null";
  if (typeof value === "boolean")
    return value ? "true" : "false";
  if (typeof value === "number")
    return String(value);
  if (typeof value === "string")
    return pyJsonStr(value);
  if (Array.isArray(value))
    return "[" + value.map((v) => jsonDumpsDefault(v)).join(", ") + "]";
  if (typeof value === "object")
    return "{" + Object.entries(value).map(([k, v]) => pyJsonStr(k) + ": " + jsonDumpsDefault(v)).join(", ") + "}";
  return "null";
}
__name(jsonDumpsDefault, "jsonDumpsDefault");
function findRootRestApiRecursive(self, currentNode) {
  const nodeMap = self.nodeMap ?? {};
  const connectionsSource = currentNode.connections?.source ?? {};
  const apiKeys = connectionsSource["aws_api_gateway_rest_api"] ?? [];
  if (apiKeys.length > 0)
    return nodeMap[apiKeys[0]] ?? null;
  const resourceKeys = connectionsSource["aws_api_gateway_resource"] ?? [];
  if (resourceKeys.length > 0) {
    const parentNode = nodeMap[resourceKeys[0]];
    if (parentNode)
      return findRootRestApiRecursive(self, parentNode);
  }
  return null;
}
__name(findRootRestApiRecursive, "findRootRestApiRecursive");
function getContextFromMethod(self, methodNode) {
  if (!methodNode)
    return [null, null, null];
  const nodeMap = self.nodeMap ?? {};
  const methodLogicalName = methodNode.logicalName;
  const httpMethodHcl = `aws_api_gateway_method.${methodLogicalName}.http_method`;
  const connectionsSource = methodNode.connections?.source ?? {};
  const resourceKeys = connectionsSource["aws_api_gateway_resource"] ?? [];
  const apiKeys = connectionsSource["aws_api_gateway_rest_api"] ?? [];
  let restApiId = null;
  let resourceId = null;
  if (resourceKeys.length > 0) {
    const resNode = nodeMap[resourceKeys[0]];
    if (resNode) {
      resourceId = `aws_api_gateway_resource.${resNode.logicalName}.id`;
      const rootApiNode = findRootRestApiRecursive(self, resNode);
      if (rootApiNode)
        restApiId = `aws_api_gateway_rest_api.${rootApiNode.logicalName}.id`;
    }
  } else if (apiKeys.length > 0) {
    const apiNode = nodeMap[apiKeys[0]];
    if (apiNode) {
      restApiId = `aws_api_gateway_rest_api.${apiNode.logicalName}.id`;
      resourceId = `aws_api_gateway_rest_api.${apiNode.logicalName}.root_resource_id`;
    }
  }
  return [restApiId, resourceId, httpMethodHcl];
}
__name(getContextFromMethod, "getContextFromMethod");
function sanitizeVtlTemplates(templatesInput) {
  if (!templatesInput)
    return null;
  if (isPlainObject2(templatesInput))
    return templatesInput;
  let cleanInput = String(templatesInput).trim();
  if (cleanInput.startsWith("jsonencode(") && cleanInput.endsWith(")")) {
    cleanInput = cleanInput.slice(11, -1).trim();
    if (cleanInput.startsWith('"') && cleanInput.endsWith('"')) {
      try {
        cleanInput = JSON.parse(cleanInput);
      } catch {
      }
    }
  }
  try {
    return JSON.parse(cleanInput);
  } catch {
  }
  try {
    return JSON.parse(cleanInput.replaceAll(" = ", ":"));
  } catch {
  }
  if (cleanInput.includes("application/json")) {
    const match = /"application\/json"\s*=\s*"(.*?)"/s.exec(cleanInput);
    if (match)
      return { "application/json": match[1].replaceAll('\\"', '"') };
  }
  return null;
}
__name(sanitizeVtlTemplates, "sanitizeVtlTemplates");
function handleAwsApiGatewayResource(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const connectionsSource = node.connections?.source ?? {};
  const parentApiKeys = connectionsSource["aws_api_gateway_rest_api"] ?? [];
  const parentResourceKeys = connectionsSource["aws_api_gateway_resource"] ?? [];
  if (parentApiKeys.length > 0) {
    const apiNode = nodeMap[parentApiKeys[0]];
    if (apiNode) {
      const apiLogicalName = apiNode.logicalName;
      params["parent_id"] = `aws_api_gateway_rest_api.${apiLogicalName}.root_resource_id`;
      params["rest_api_id"] = `aws_api_gateway_rest_api.${apiLogicalName}.id`;
    }
  } else if (parentResourceKeys.length > 0) {
    const parentResNode = nodeMap[parentResourceKeys[0]];
    if (parentResNode) {
      params["parent_id"] = `aws_api_gateway_resource.${parentResNode.logicalName}.id`;
      const rootApiNode = findRootRestApiRecursive(self, parentResNode);
      if (rootApiNode)
        params["rest_api_id"] = `aws_api_gateway_rest_api.${rootApiNode.logicalName}.id`;
    }
  }
  return node;
}
__name(handleAwsApiGatewayResource, "handleAwsApiGatewayResource");
function handleAwsApiGatewayMethod(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const connectionsSource = node.connections?.source ?? {};
  const resourceKeys = connectionsSource["aws_api_gateway_resource"] ?? [];
  const apiKeys = connectionsSource["aws_api_gateway_rest_api"] ?? [];
  if (resourceKeys.length > 0) {
    const resNode = nodeMap[resourceKeys[0]];
    if (resNode) {
      params["resource_id"] = `aws_api_gateway_resource.${resNode.logicalName}.id`;
      const rootApiNode = findRootRestApiRecursive(self, resNode);
      if (rootApiNode)
        params["rest_api_id"] = `aws_api_gateway_rest_api.${rootApiNode.logicalName}.id`;
    }
  } else if (apiKeys.length > 0) {
    const apiNode = nodeMap[apiKeys[0]];
    if (apiNode) {
      params["rest_api_id"] = `aws_api_gateway_rest_api.${apiNode.logicalName}.id`;
      params["resource_id"] = `aws_api_gateway_rest_api.${apiNode.logicalName}.root_resource_id`;
    }
  }
  const currentAuth = params["authorization"] ?? "NONE";
  const authorizerKeys = connectionsSource["aws_api_gateway_authorizer"] ?? [];
  const iamKeys = [...connectionsSource["aws_iam_role"] ?? [], ...connectionsSource["aws_iam_policy"] ?? []];
  if (authorizerKeys.length > 0) {
    const authNode = nodeMap[authorizerKeys[0]];
    params["authorizer_id"] = `aws_api_gateway_authorizer.${authNode.logicalName}.id`;
    const authSources = authNode.connections?.source ?? {};
    params["authorization"] = "aws_cognito_user_pool" in authSources ? "COGNITO_USER_POOLS" : "CUSTOM";
  } else if (iamKeys.length > 0 && currentAuth === "NONE") {
    params["authorization"] = "AWS_IAM";
  }
  const modelKeys = connectionsSource["aws_api_gateway_model"] ?? [];
  if (modelKeys.length > 0) {
    if (!("request_models" in params) || !isPlainObject2(params["request_models"]))
      params["request_models"] = {};
    for (const key of modelKeys) {
      const modelNode = nodeMap[key];
      if (!modelNode)
        continue;
      const modelParams = modelNode.cloudResource?.params ?? {};
      const contentType = modelParams["content_type"] ?? "application/json";
      params["request_models"][contentType] = `aws_api_gateway_model.${modelNode.logicalName}.name`;
    }
  }
  const validatorKeys = connectionsSource["aws_api_gateway_request_validator"] ?? [];
  if (validatorKeys.length > 0) {
    const valNode = nodeMap[validatorKeys[0]];
    params["request_validator_id"] = `aws_api_gateway_request_validator.${valNode.logicalName}.id`;
  }
  return node;
}
__name(handleAwsApiGatewayMethod, "handleAwsApiGatewayMethod");
function configureLambdaIntegration(intNode, lambdaNode, methodVerb = "POST") {
  if (!lambdaNode)
    return;
  const params = intNode.cloudResource?.params ?? {};
  const lambdaName = lambdaNode.logicalName;
  if (!params["type"])
    params["type"] = "AWS_PROXY";
  const integrationType = params["type"];
  params["integration_http_method"] = "POST";
  params["uri"] = `aws_lambda_function.${lambdaName}.invoke_arn`;
  if (integrationType === "AWS")
    injectVtlTemplates(params, methodVerb);
}
__name(configureLambdaIntegration, "configureLambdaIntegration");
function configureSfnIntegration(intNode, sfnNode, roleArn) {
  if (!sfnNode)
    return;
  const params = intNode.cloudResource?.params ?? {};
  const sfnName = sfnNode.logicalName;
  params["type"] = "AWS";
  params["integration_http_method"] = "POST";
  params["uri"] = "arn:aws:apigateway:${data.aws_region.current.region}:states:action/StartExecution";
  if (roleArn)
    params["credentials"] = roleArn;
  if (!params["request_templates"]) {
    const sfnTemplate = `{
    "input": "$util.escapeJavaScript($input.body)",
    "stateMachineArn": "\${aws_sfn_state_machine.${sfnName}.arn}"
}`;
    params["request_templates"] = { "application/json": `__RAW__${sfnTemplate}` };
  }
}
__name(configureSfnIntegration, "configureSfnIntegration");
function injectVtlTemplates(params, methodVerb = "POST") {
  if (params["request_templates"])
    return;
  params["passthrough_behavior"] = "WHEN_NO_MATCH";
  const contextSection = `
  "context" : {
    "apiId" : "$context.apiId",
    "httpMethod" : "$context.httpMethod",
    "requestId" : "$context.requestId",
    "resourceId" : "$context.resourceId",
    "sourceIp" : "$context.identity.sourceIp",
    "stage" : "$context.stage",
    "user" : "$context.identity.user",
    "userAgent" : "$context.identity.userAgent",
    "userArn" : "$context.identity.userArn"
  }`;
  const foreachBlock = /* @__PURE__ */ __name((name) => `  "${name}": {
    #foreach($param in $input.params().${name === "queryParams" ? "querystring" : name === "pathParams" ? "path" : "header"}.keySet())
    "$param": "$util.escapeJavaScript($input.params().${name === "queryParams" ? "querystring" : name === "pathParams" ? "path" : "header"}.get($param))" #if($foreach.hasNext),#end
    #end
  }`, "foreachBlock");
  const vtlNoBody = `<<EOF
{
${foreachBlock("headers")},
${foreachBlock("queryParams")},
${foreachBlock("pathParams")},
${contextSection}
}
EOF`;
  const vtlWithBody = `<<EOF
{
  "body" : $input.json('$'),
${foreachBlock("headers")},
${foreachBlock("queryParams")},
${foreachBlock("pathParams")},
${contextSection}
}
EOF`;
  const selected = ["GET", "DELETE", "HEAD", "OPTIONS"].includes(methodVerb.toUpperCase()) ? vtlNoBody : vtlWithBody;
  params["request_templates"] = { "application/json": `__RAW__${selected}` };
}
__name(injectVtlTemplates, "injectVtlTemplates");
function findConnectedIamRole(self, node) {
  const connections = node.connections?.source ?? {};
  const roleKeys = connections["aws_iam_role"] ?? [];
  if (roleKeys.length > 0) {
    const roleName = self.nodeMap?.[roleKeys[0]]?.logicalName;
    return `aws_iam_role.${roleName}.arn`;
  }
  return null;
}
__name(findConnectedIamRole, "findConnectedIamRole");
function handleAwsApiGatewayIntegration(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const connectionsSource = node.connections?.source ?? {};
  const connectionsTarget = node.connections?.target ?? {};
  let currentHttpVerb = "POST";
  const methodKeys = connectionsSource["aws_api_gateway_method"] ?? [];
  if (methodKeys.length > 0) {
    const methodNode = nodeMap[methodKeys[0]];
    const [apiId, resId, httpMethodRef] = getContextFromMethod(self, methodNode);
    const methodParams = methodNode?.cloudResource?.params ?? {};
    currentHttpVerb = methodParams["http_method"] ?? "POST";
    if (apiId && resId) {
      params["rest_api_id"] = apiId;
      params["resource_id"] = resId;
      params["http_method"] = httpMethodRef;
    }
  }
  if ("request_templates" in params)
    params["request_templates"] = sanitizeVtlTemplates(params["request_templates"]);
  if ("aws_lambda_function" in connectionsTarget) {
    const lambdaKeys = connectionsTarget["aws_lambda_function"];
    if (lambdaKeys.length > 0)
      configureLambdaIntegration(node, nodeMap[lambdaKeys[0]], currentHttpVerb);
  } else if ("aws_sfn_state_machine" in connectionsTarget) {
    const sfnKeys = connectionsTarget["aws_sfn_state_machine"];
    if (sfnKeys.length > 0)
      configureSfnIntegration(node, nodeMap[sfnKeys[0]], findConnectedIamRole(self, node));
  } else if ("aws_lb_target_group" in connectionsTarget) {
    const tgKeys = connectionsTarget["aws_lb_target_group"];
    if (tgKeys.length > 0) {
      throw new Error("Python arity bug: _configure_alb_integration called with node_map -> TypeError");
    }
  } else if (params["type"] === "MOCK") {
    if (!params["request_templates"])
      params["request_templates"] = { "application/json": '{"statusCode": 200}' };
    params["passthrough_behavior"] = "WHEN_NO_MATCH";
  }
  return node;
}
__name(handleAwsApiGatewayIntegration, "handleAwsApiGatewayIntegration");
function collectApiDependencies(self, rootNode) {
  const nodeMap = self.nodeMap ?? {};
  const dependencies = [];
  const visited = /* @__PURE__ */ new Set();
  const queue = [rootNode];
  const relevantTypes = [
    "aws_api_gateway_resource",
    "aws_api_gateway_method",
    "aws_api_gateway_integration",
    "aws_api_gateway_method_response",
    "aws_api_gateway_integration_response"
  ];
  while (queue.length > 0) {
    const current = queue.shift();
    if (visited.has(current.key))
      continue;
    visited.add(current.key);
    if (relevantTypes.includes(current.type)) {
      dependencies.push(`${current.type}.${current.logicalName}.id`);
    }
    const targets = current.connections?.target ?? {};
    for (const cType of relevantTypes) {
      if (cType in targets) {
        for (const key of targets[cType]) {
          const childNode = nodeMap[key];
          if (childNode)
            queue.push(childNode);
        }
      }
    }
  }
  return dependencies;
}
__name(collectApiDependencies, "collectApiDependencies");
function handleAwsApiGatewayDeployment(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  node.cloudResource ??= {};
  node.cloudResource.params ??= {};
  const params = node.cloudResource.params;
  const connectionsSource = node.connections?.source ?? {};
  const apiKeys = connectionsSource["aws_api_gateway_rest_api"] ?? [];
  if (apiKeys.length === 0)
    return node;
  const apiNode = nodeMap[apiKeys[0]];
  const apiName = apiNode.logicalName;
  params["rest_api_id"] = `aws_api_gateway_rest_api.${apiName}.id`;
  const tradDependenciesIds = collectApiDependencies(self, apiNode);
  let openapiDependency = null;
  const apiTargets = apiNode.connections?.target ?? {};
  const openapiKeys = apiTargets["cldmn_open_api"] ?? [];
  if (openapiKeys.length > 0)
    openapiDependency = `aws_api_gateway_rest_api.${apiName}.body`;
  const triggerList = [];
  if (tradDependenciesIds.length > 0) {
    const jsonListStr = "[\n" + tradDependenciesIds.join(",\n") + "\n]";
    triggerList.push(`jsonencode(${jsonListStr})`);
  }
  if (openapiDependency)
    triggerList.push(`jsonencode(${openapiDependency})`);
  if (triggerList.length > 0) {
    const combinedTriggers = `join(",", [${triggerList.join(", ")}])`;
    params["triggers"] = { redeployment: `sha1(${combinedTriggers})` };
  }
  const resourceRefs = tradDependenciesIds.map((dep) => dep.slice(0, dep.lastIndexOf(".")));
  let currentDepends = params["depends_on"] ?? [];
  if (!Array.isArray(currentDepends))
    currentDepends = [];
  params["depends_on"] = [.../* @__PURE__ */ new Set([...currentDepends, ...resourceRefs])];
  return node;
}
__name(handleAwsApiGatewayDeployment, "handleAwsApiGatewayDeployment");
function configureStageAccessLogs(self, stageParams, cwKeys, apiLogicalName, stageName) {
  if (cwKeys.length === 0)
    return;
  const cwNode = self.nodeMap?.[cwKeys[0]];
  if (!cwNode)
    return;
  const cwLogicalName = cwNode.logicalName;
  cwNode.cloudResource ??= {};
  cwNode.cloudResource.params ??= {};
  const cwParams = cwNode.cloudResource.params;
  if (!cwParams["name"])
    cwParams["name"] = `/aws/apigateway/${apiLogicalName}/${stageName}`;
  if (!("access_log_settings" in stageParams) || !stageParams["access_log_settings"])
    stageParams["access_log_settings"] = [{}];
  stageParams["access_log_settings"][0]["destination_arn"] = `aws_cloudwatch_log_group.${cwLogicalName}.arn`;
  const logSettings = stageParams["access_log_settings"][0];
  if ("format" in logSettings && isPlainObject2(logSettings["format"])) {
    const jsonString = jsonDumpsDefault(logSettings["format"]);
    logSettings["format"] = `jsonencode(${jsonString})`;
  }
}
__name(configureStageAccessLogs, "configureStageAccessLogs");
function handleAwsApiGatewayStage(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const connectionsSource = node.connections?.source ?? {};
  const connectionsTarget = node.connections?.target ?? {};
  const stageName = params["stage_name"] ?? "dev";
  let apiLogicalName = "api";
  const apiKeys = connectionsSource["aws_api_gateway_rest_api"] ?? [];
  let apiNode = null;
  if (apiKeys.length > 0) {
    apiNode = nodeMap[apiKeys[0]];
    apiLogicalName = apiNode.logicalName;
    params["rest_api_id"] = `aws_api_gateway_rest_api.${apiLogicalName}.id`;
  }
  let deployKeys = connectionsTarget["aws_api_gateway_deployment"] ?? [];
  if (deployKeys.length === 0)
    deployKeys = connectionsSource["aws_api_gateway_deployment"] ?? [];
  if (deployKeys.length === 0 && apiNode)
    deployKeys = apiNode.connections?.target?.["aws_api_gateway_deployment"] ?? [];
  if (deployKeys.length > 0) {
    const deployNode = nodeMap[deployKeys[0]];
    params["deployment_id"] = `aws_api_gateway_deployment.${deployNode.logicalName}.id`;
  }
  const cwKeys = connectionsTarget["aws_cloudwatch_log_group"] ?? [];
  configureStageAccessLogs(self, params, cwKeys, apiLogicalName, stageName);
  const certKeys = connectionsSource["aws_api_gateway_client_certificate"] ?? [];
  if (certKeys.length > 0) {
    const certNode = nodeMap[certKeys[0]];
    params["client_certificate_id"] = `aws_api_gateway_client_certificate.${certNode.logicalName}.id`;
  }
  return node;
}
__name(handleAwsApiGatewayStage, "handleAwsApiGatewayStage");
function findMethodAncestor(self, currentNode) {
  const nodeMap = self.nodeMap ?? {};
  const sources = currentNode.connections?.source ?? {};
  if ("aws_api_gateway_method" in sources)
    return nodeMap[sources["aws_api_gateway_method"][0]] ?? null;
  if ("aws_api_gateway_integration_response" in sources) {
    const intRespNode = nodeMap[sources["aws_api_gateway_integration_response"][0]];
    if (intRespNode)
      return findMethodAncestor(self, intRespNode);
  }
  if ("aws_api_gateway_integration" in sources) {
    const intNode = nodeMap[sources["aws_api_gateway_integration"][0]];
    if (intNode)
      return findMethodAncestor(self, intNode);
  }
  return null;
}
__name(findMethodAncestor, "findMethodAncestor");
function handleAwsApiGatewayMethodResponse(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const methodNode = findMethodAncestor(self, node);
  if (methodNode) {
    const [apiId, resId, httpMethod] = getContextFromMethod(self, methodNode);
    if (apiId && resId) {
      params["rest_api_id"] = apiId;
      params["resource_id"] = resId;
      params["http_method"] = httpMethod;
    }
  }
  if (!("response_models" in params) || !params["response_models"])
    params["response_models"] = { "application/json": "Empty" };
  if ("response_parameters" in params && isPlainObject2(params["response_parameters"])) {
    for (const [key, val] of Object.entries(params["response_parameters"])) {
      if (typeof val === "string")
        params["response_parameters"][key] = val.toLowerCase() === "true";
    }
  }
  return node;
}
__name(handleAwsApiGatewayMethodResponse, "handleAwsApiGatewayMethodResponse");
function handleAwsApiGatewayIntegrationResponse(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const connectionsSource = node.connections?.source ?? {};
  const integrationKeys = connectionsSource["aws_api_gateway_integration"] ?? [];
  if (integrationKeys.length === 0)
    return node;
  const intNode = nodeMap[integrationKeys[0]];
  const intParams = intNode.cloudResource?.params ?? {};
  if (intParams["type"] === "AWS_PROXY")
    return node;
  const intLogicalName = intNode.logicalName;
  if (!("depends_on" in params))
    params["depends_on"] = [];
  const dependencyRef = `aws_api_gateway_integration.${intLogicalName}`;
  if (!params["depends_on"].includes(dependencyRef))
    params["depends_on"].push(dependencyRef);
  const intSource = intNode.connections?.source ?? {};
  const methodKeys = intSource["aws_api_gateway_method"] ?? [];
  if (methodKeys.length > 0) {
    const methodNode = nodeMap[methodKeys[0]];
    const [apiId, resId, httpMethod] = getContextFromMethod(self, methodNode);
    if (apiId && resId) {
      params["rest_api_id"] = apiId;
      params["resource_id"] = resId;
      params["http_method"] = httpMethod;
    }
    if (!params["status_code"]) {
      const methodTargets = methodNode.connections?.target ?? {};
      const mrespKeys = methodTargets["aws_api_gateway_method_response"] ?? [];
      if (mrespKeys.length > 0) {
        const mrespNode = nodeMap[mrespKeys[0]];
        const mrespParams = mrespNode.cloudResource?.params ?? {};
        params["status_code"] = mrespParams["status_code"] ?? "200";
      }
    }
  }
  if ("response_templates" in params && params["response_templates"]) {
    params["response_templates"] = sanitizeVtlTemplates(params["response_templates"]);
  }
  return node;
}
__name(handleAwsApiGatewayIntegrationResponse, "handleAwsApiGatewayIntegrationResponse");
function handleAwsApiGatewayAccount(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const accountLogicalName = node.logicalName;
  const connectionsSource = node.connections?.source ?? {};
  const roleKeys = connectionsSource["aws_iam_role"] ?? [];
  if (roleKeys.length === 0)
    return node;
  const roleNode = nodeMap[roleKeys[0]];
  const roleLogicalName = roleNode.logicalName;
  const attachLogicalName = `attach_cw_${accountLogicalName}`;
  const attachNode = self.addGenericNode(self.generatedNodes, "aws_iam_role_policy_attachment", attachLogicalName, null, node);
  if (attachNode) {
    const attachParams = attachNode.cloudResource.params;
    attachParams["role"] = `aws_iam_role.${roleLogicalName}.name`;
    attachParams["policy_arn"] = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs";
    attachNode.connections = attachNode.connections ?? { source: {}, target: {} };
    attachNode.connections.target = { aws_iam_role: [roleNode.key] };
  }
  params["cloudwatch_role_arn"] = `aws_iam_role.${roleLogicalName}.arn`;
  return node;
}
__name(handleAwsApiGatewayAccount, "handleAwsApiGatewayAccount");
function getVtlTemplate(serviceKey) {
  if (serviceKey === "lambda_no_proxy") {
    return `{ "body" : $input.json('$'), "method": "$context.httpMethod", "params": { #foreach($param in $input.params().path.keySet()) "$param": "$util.escapeJavaScript($input.params().path.get($param))" #if($foreach.hasNext),#end #end } }`;
  }
  return "{}";
}
__name(getVtlTemplate, "getVtlTemplate");
function normalizeStatements(rawStatements) {
  const normalized = [];
  for (const stmt of rawStatements) {
    const effect = stmt["Effect"] || stmt["effect"] || "Allow";
    const newStmt = { effect };
    const rawAction = stmt["Action"] || stmt["actions"];
    if (rawAction)
      newStmt["actions"] = Array.isArray(rawAction) ? rawAction : [rawAction];
    const rawResource = stmt["Resource"] || stmt["resources"];
    if (rawResource)
      newStmt["resources"] = Array.isArray(rawResource) ? rawResource : [rawResource];
    const rawSid = stmt["Sid"] || stmt["sid"];
    if (rawSid)
      newStmt["sid"] = rawSid;
    normalized.push(newStmt);
  }
  return normalized;
}
__name(normalizeStatements, "normalizeStatements");
function extractPolicyFromGraph(self, openapiNode, targetNode) {
  const nodeMap = self.nodeMap ?? {};
  const policyKeys = openapiNode.connections?.target?.["cldmn_policy"] ?? [];
  const targetKey = targetNode.key;
  for (const pKey of policyKeys) {
    const policyNode = nodeMap[pKey];
    if (!policyNode)
      continue;
    const policyTargets = policyNode.connections?.target ?? {};
    const allTargetKeys = [];
    for (const tList of Object.values(policyTargets))
      allTargetKeys.push(...tList);
    if (allTargetKeys.includes(targetKey)) {
      const params = policyNode.cloudResource?.params ?? {};
      let statements = params["statement"] ?? [];
      if (isPlainObject2(statements))
        statements = [statements];
      return statements;
    }
  }
  return [];
}
__name(extractPolicyFromGraph, "extractPolicyFromGraph");
function ensureIntegrationRole(self, gatewayNode, targetNode, openapiNode, _nodeMap) {
  const gwName = gatewayNode.logicalName;
  const targetName = targetNode.logicalName;
  const roleLogicalName = `role_apigw_${gwName}_to_${targetName}`;
  const createdRoles = self._createdRoles ??= /* @__PURE__ */ new Set();
  if (createdRoles.has(roleLogicalName))
    return `aws_iam_role.${roleLogicalName}.arn`;
  createdRoles.add(roleLogicalName);
  const trustDocLogicalName = `doc_trust_${roleLogicalName}`;
  const trustDocNode = self.addGenericNode(self.generatedNodes, "aws_iam_policy_document", trustDocLogicalName);
  if (trustDocNode) {
    trustDocNode["_temp_data_source_definition"] = {
      XTYPE: "aws_iam_policy_document",
      logicalName: trustDocLogicalName,
      statement: [{ effect: "Allow", actions: ["sts:AssumeRole"], principals: [{ type: "Service", identifiers: ["apigateway.amazonaws.com"] }] }]
    };
    trustDocNode.cloudResource.params = {};
  }
  const roleNode = self.addGenericNode(self.generatedNodes, "aws_iam_role", roleLogicalName);
  if (roleNode) {
    roleNode.cloudResource.params = {
      name: `api-${gwName}-${targetName}-role`.slice(0, 64),
      assume_role_policy: `data.aws_iam_policy_document.${trustDocLogicalName}.json`
    };
  }
  const rawStatements = extractPolicyFromGraph(self, openapiNode, targetNode);
  if (rawStatements.length > 0) {
    const permDocLogicalName = `doc_perm_${roleLogicalName}`;
    const hclStatements = normalizeStatements(rawStatements);
    const permDocNode = self.addGenericNode(self.generatedNodes, "aws_iam_policy_document", permDocLogicalName);
    if (permDocNode) {
      permDocNode["_temp_data_source_definition"] = { XTYPE: "aws_iam_policy_document", logicalName: permDocLogicalName, statement: hclStatements };
      permDocNode.cloudResource.params = {};
    }
    const policyNode = self.addGenericNode(self.generatedNodes, "aws_iam_role_policy", `policy_${roleLogicalName}`);
    if (policyNode) {
      policyNode.cloudResource.params = {
        name: `access-${targetName}`,
        role: `aws_iam_role.${roleLogicalName}.id`,
        policy: `data.aws_iam_policy_document.${permDocLogicalName}.json`
      };
    }
  }
  return `aws_iam_role.${roleLogicalName}.arn`;
}
__name(ensureIntegrationRole, "ensureIntegrationRole");
function openApiAwsS3Bucket(self, node, ctx) {
  const targetName = node.logicalName;
  const path = `/${targetName.toLowerCase()}/{proxy+}`;
  const uri = `arn:aws:apigateway:${ctx.region}:s3:path/${targetName}/{proxy}`;
  const roleArn = ensureIntegrationRole(self, ctx.gateway_node, node, ctx.openapi_node, ctx.node_map);
  return {
    path,
    uri,
    type: "aws",
    methods: ctx.global_methods.map((m) => m.toLowerCase()),
    enable_mock: ctx.enable_mock,
    credentials: roleArn,
    requestTemplates: {},
    integ_method: '"MATCH"',
    parameters: `[
          {
            name = "proxy"
            in = "path"
            required = true
            schema = { type = "string" }
          }
        ]`,
    integ_req_params: { "integration.request.path.proxy": "method.request.path.proxy" }
  };
}
__name(openApiAwsS3Bucket, "openApiAwsS3Bucket");
function openApiAwsSqsQueue(self, node, ctx) {
  const targetName = node.logicalName;
  const uri = `arn:aws:apigateway:${ctx.region}:sqs:path/${ctx.account_id}/${targetName}`;
  const roleArn = ensureIntegrationRole(self, ctx.gateway_node, node, ctx.openapi_node, ctx.node_map);
  const universalVtl = "#set($method = $context.httpMethod)#if($method == 'POST' || $method == 'PUT')Action=SendMessage&MessageBody=$util.urlEncode($input.body)#elseif($method == 'GET')Action=ReceiveMessage&MaxNumberOfMessages=10&WaitTimeSeconds=20&VisibilityTimeout=30#elseif($method == 'DELETE')Action=DeleteMessage&ReceiptHandle=$util.urlEncode($input.params('receiptHandle'))#elseif($method == 'HEAD')Action=GetQueueAttributes&AttributeName=ApproximateNumberOfMessages#elseAction=GetQueueAttributes#end";
  const sqsParameters = `[
          {
            "name": "receiptHandle",
            "in": "query",
            "required": false,
            "schema": { "type": "string" }
          }
        ]`;
  return {
    path: `/${targetName}`,
    uri,
    type: "aws",
    methods: ["get", "post", "put", "delete", "head", "options"],
    enable_mock: ctx.enable_mock,
    credentials: roleArn,
    requestTemplates: { "application/json": universalVtl, "application/x-www-form-urlencoded": universalVtl, "text/plain": universalVtl },
    integ_method: '"POST"',
    parameters: sqsParameters,
    integ_req_params: { "integration.request.header.Content-Type": "'application/x-www-form-urlencoded'" }
  };
}
__name(openApiAwsSqsQueue, "openApiAwsSqsQueue");
function openApiAwsDynamodbTable(self, node, ctx) {
  const targetName = node.logicalName;
  const params = node.cloudResource?.params ?? {};
  const hashKey = params["hash_key"];
  const rangeKey = params["range_key"];
  const attributes = params["attribute"] ?? [];
  if (!hashKey)
    return null;
  const getDynamoType = /* @__PURE__ */ __name((keyName) => {
    if (Array.isArray(attributes)) {
      for (const attr of attributes)
        if (attr["name"] === keyName)
          return attr["type"] ?? "S";
    }
    return "S";
  }, "getDynamoType");
  const hashType = getDynamoType(hashKey);
  let resourcePath = `/${targetName}/{${hashKey}}`;
  const openapiParams = [{ name: hashKey, in: "path", required: true, schema: { type: "string" } }];
  if (rangeKey) {
    resourcePath += `/{${rangeKey}}`;
    openapiParams.push({ name: rangeKey, in: "path", required: true, schema: { type: "string" } });
  }
  const parametersJson = jsonDumpsDefault(openapiParams);
  let keyJson = `"${hashKey}": { "${hashType}": "$util.escapeJavaScript($input.params('${hashKey}'))" }`;
  if (rangeKey) {
    const rangeType = getDynamoType(rangeKey);
    keyJson += `, "${rangeKey}": { "${rangeType}": "$util.escapeJavaScript($input.params('${rangeKey}'))" }`;
  }
  const itemJson = keyJson + ', "Payload": { "S": "$util.escapeJavaScript($input.body)" }';
  const roleArn = ensureIntegrationRole(self, ctx.gateway_node, node, ctx.openapi_node, ctx.node_map);
  const configs = [];
  const userMethods = ctx.global_methods.map((m) => m.toLowerCase());
  if (userMethods.includes("get")) {
    configs.push({
      path: resourcePath,
      uri: `arn:aws:apigateway:${ctx.region}:dynamodb:action/GetItem`,
      type: "aws",
      methods: ["get"],
      enable_mock: ctx.enable_mock,
      credentials: roleArn,
      requestTemplates: { "application/json": `{"TableName": "${targetName}", "Key": { ${keyJson} } }` },
      integ_method: '"POST"',
      parameters: parametersJson
    });
  }
  if (userMethods.includes("delete")) {
    configs.push({
      path: resourcePath,
      uri: `arn:aws:apigateway:${ctx.region}:dynamodb:action/DeleteItem`,
      type: "aws",
      methods: ["delete"],
      enable_mock: ctx.enable_mock,
      credentials: roleArn,
      requestTemplates: { "application/json": `{"TableName": "${targetName}", "Key": { ${keyJson} } }` },
      integ_method: '"POST"',
      parameters: parametersJson
    });
  }
  const writeMethods = userMethods.filter((m) => m === "post" || m === "put");
  if (writeMethods.length > 0) {
    configs.push({
      path: resourcePath,
      uri: `arn:aws:apigateway:${ctx.region}:dynamodb:action/PutItem`,
      type: "aws",
      methods: writeMethods,
      enable_mock: ctx.enable_mock,
      credentials: roleArn,
      requestTemplates: { "application/json": `{"TableName": "${targetName}", "Item": { ${itemJson} } }` },
      integ_method: '"POST"',
      parameters: parametersJson
    });
  }
  return configs;
}
__name(openApiAwsDynamodbTable, "openApiAwsDynamodbTable");
function openApiAwsLambdaFunction(self, node, ctx) {
  const targetName = node.logicalName;
  const uri = `arn:aws:apigateway:${ctx.region}:lambda:path/2015-03-31/functions/arn:aws:lambda:${ctx.region}:${ctx.account_id}:function:${targetName}/invocations`;
  let integType;
  let templates;
  if (ctx.use_proxy) {
    integType = "aws_proxy";
    templates = null;
  } else {
    integType = "aws";
    templates = { "application/json": getVtlTemplate("lambda_no_proxy") };
  }
  return {
    path: `/${targetName}`,
    uri,
    type: integType,
    methods: ctx.global_methods.map((m) => m.toLowerCase()),
    enable_mock: ctx.enable_mock,
    credentials: null,
    requestTemplates: templates,
    integ_method: '"POST"',
    parameters: "null"
  };
}
__name(openApiAwsLambdaFunction, "openApiAwsLambdaFunction");
var OPEN_API_HANDLERS = {
  aws_s3_bucket: openApiAwsS3Bucket,
  aws_sqs_queue: openApiAwsSqsQueue,
  aws_dynamodb_table: openApiAwsDynamodbTable,
  aws_lambda_function: openApiAwsLambdaFunction
};
function extractOpenapiData(self, gatewayNode, openapiNode) {
  const nodeMap = self.nodeMap ?? {};
  const params = openapiNode.cloudResource?.params ?? {};
  const apiName = gatewayNode.logicalName;
  const ctx = {
    global_methods: params["http_methods"] || ["POST"],
    enable_mock: params["enable_mock_options"] ?? true,
    use_proxy: params["use_proxy_integration"] ?? true,
    gateway_node: gatewayNode,
    openapi_node: openapiNode,
    node_map: nodeMap,
    region: "",
    account_id: "${data.aws_caller_identity.current.account_id}"
  };
  const [, regionFound] = findAccountAndRegionName(gatewayNode, nodeMap);
  ctx.region = regionFound ? regionFound : "${data.aws_region.current.region}";
  const sourcesMap = openapiNode.connections?.source ?? {};
  let authConfig = null;
  const cognitoKeys = sourcesMap["aws_cognito_user_pool"] ?? [];
  if (cognitoKeys.length > 0) {
    const cognitoNode = nodeMap[cognitoKeys[0]];
    if (cognitoNode) {
      const cognitoLogicalName = cognitoNode.logicalName;
      authConfig = {
        name: `${apiName}_CognitoAuth_${cognitoLogicalName}`,
        arn_ref: `aws_cognito_user_pool.${cognitoLogicalName}.arn`,
        type: "cognito_user_pools"
      };
    }
  }
  const targetsMap = openapiNode.connections?.target ?? {};
  const extractedRoutes = [];
  for (const [resourceType, resourceKeys] of Object.entries(targetsMap)) {
    if (resourceType.startsWith("cldmn_"))
      continue;
    const handlerFunc = OPEN_API_HANDLERS[resourceType];
    if (!handlerFunc)
      continue;
    for (const resKey of resourceKeys) {
      const targetNode = nodeMap[resKey];
      if (!targetNode)
        continue;
      const itemConfig = handlerFunc(self, targetNode, ctx);
      if (itemConfig) {
        const configsList = Array.isArray(itemConfig) ? itemConfig : [itemConfig];
        for (const config2 of configsList) {
          for (const method of config2["methods"] ?? []) {
            const routeData = { ...config2 };
            routeData["method"] = method.toLowerCase();
            routeData["auth_name"] = authConfig ? authConfig["name"] : null;
            extractedRoutes.push(routeData);
          }
        }
      }
    }
  }
  return [extractedRoutes, authConfig];
}
__name(extractOpenapiData, "extractOpenapiData");
function consolidateOpenapiRoutes(allRoutes) {
  const consolidatedMap = /* @__PURE__ */ new Map();
  for (const r of allRoutes) {
    const key = `${r["path"]}\0${r["uri"]}`;
    if (!consolidatedMap.has(key)) {
      consolidatedMap.set(key, {
        path: r["path"],
        uri: r["uri"],
        type: r["type"],
        methods: /* @__PURE__ */ new Set(),
        method_auth: {},
        enable_mock: r["enable_mock"] ?? false,
        credentials: r["credentials"],
        requestTemplates: r["requestTemplates"],
        integ_method: r["integ_method"],
        parameters: r["parameters"],
        integ_req_params: r["integ_req_params"]
      });
    }
    const block = consolidatedMap.get(key);
    const method = r["method"];
    block["methods"].add(method);
    if (r["auth_name"])
      block["method_auth"][method] = r["auth_name"];
    if (r["enable_mock"])
      block["enable_mock"] = true;
  }
  const finalList = [...consolidatedMap.values()];
  for (const item of finalList)
    item["methods"] = [...item["methods"]];
  return finalList;
}
__name(consolidateOpenapiRoutes, "consolidateOpenapiRoutes");
function buildHclItem(config2) {
  const methodsJson = jsonDumpsDefault(config2["methods"]);
  const boolMock = config2["enable_mock"] ? "true" : "false";
  const credVal = config2["credentials"] ? config2["credentials"] : "null";
  let tplStr = "null";
  if (config2["requestTemplates"]) {
    tplStr = "{\n";
    for (const [ctype, vtl] of Object.entries(config2["requestTemplates"])) {
      const safeVtl = String(vtl).replaceAll('"', '\\"').replaceAll("\n", "\\n");
      tplStr += `        "${ctype}" = "${safeVtl}"
`;
    }
    tplStr += "      }";
  }
  let integParamsStr = "null";
  if (config2["integ_req_params"]) {
    integParamsStr = "{\n";
    for (const [k, v] of Object.entries(config2["integ_req_params"])) {
      integParamsStr += `        "${k}" = "${v}"
`;
    }
    integParamsStr += "      }";
  }
  const methodAuthItems = [];
  for (const [m, authName] of Object.entries(config2["method_auth"] ?? {}))
    methodAuthItems.push(`"${m}" = "${authName}"`);
  const methodAuthStr = "{" + methodAuthItems.join(", ") + "}";
  const integMethodVal = config2["integ_method"];
  return `    {
      path             = "${config2["path"]}"
      uri              = "${config2["uri"]}"
      type             = "${config2["type"]}"
      methods          = ${methodsJson}
      method_auth      = ${methodAuthStr}
      enable_mock      = ${boolMock}
      credentials      = ${credVal}
      requestTemplates = ${tplStr}
      integ_method     = ${integMethodVal}
      parameters       = ${config2["parameters"]}
      integ_req_params = ${integParamsStr}
    },
`;
}
__name(buildHclItem, "buildHclItem");
function generateCorsMockBlockString(origin, corsMethods) {
  return `{
          summary  = "CORS support"
          security = []  # <--- CORRE\xC7\xC3O 1: Anula o authorizer global para o OPTIONS
          consumes = ["application/json"]
          produces = ["application/json"]
          responses = {
            "200" = {
              description = "200 response"
              headers = {
                "Access-Control-Allow-Origin"  = { type = "string" }
                "Access-Control-Allow-Methods" = { type = "string" }
                "Access-Control-Allow-Headers" = { type = "string" }
              }
            }
          }
          "x-amazon-apigateway-integration" = {
            type = "mock"
            requestTemplates = { "application/json" = "{\\"statusCode\\": 200}" }
            responses = {
              default = {
                statusCode = "200"
                responseParameters = {
                  "method.response.header.Access-Control-Allow-Methods" = "'${corsMethods}'"
                  "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
                  "method.response.header.Access-Control-Allow-Origin"  = "'${origin}'"
                }
              }
            }
          }
        }`;
}
__name(generateCorsMockBlockString, "generateCorsMockBlockString");
function generateOpenapiSpecHcl(apiName, consolidatedRoutes, corsOrigin, authConfigsMap) {
  const allMethods = /* @__PURE__ */ new Set();
  for (const r of consolidatedRoutes)
    for (const m of r["methods"])
      allMethods.add(m);
  const uniqueCorsMethods = [.../* @__PURE__ */ new Set([...[...allMethods].map((m) => m.toUpperCase()), "OPTIONS"])].sort();
  const corsMethods = uniqueCorsMethods.join(",");
  const mockBlock = generateCorsMockBlockString(corsOrigin, corsMethods);
  const originValue = `"'${corsOrigin}'"`;
  let componentsSection = "";
  if (Object.keys(authConfigsMap).length > 0) {
    let schemesStr = "";
    for (const [authName, authData] of Object.entries(authConfigsMap)) {
      if (authData["type"] === "cognito_user_pools") {
        schemesStr += `
            "${authName}" = {
              type = "apiKey"
              name = "Authorization"
              in   = "header"
              "x-amazon-apigateway-authtype" = "cognito_user_pools"
              "x-amazon-apigateway-authorizer" = {
                type = "cognito_user_pools"
                providerARNs = [${authData["arn_ref"]}]
              }
            }`;
      }
    }
    componentsSection = `
      components = {
        securitySchemes = {${schemesStr}
        }
      }`;
  }
  return `{
      openapi = "3.0.1"
      info = {
        title   = "${apiName}"
        version = "1.0"
      }
      ${componentsSection}
      paths = {
        for path in distinct([for i in local.api_config_${apiName} : i.path]) :
        path => merge([
          for item in local.api_config_${apiName} :
          merge(
            {
              for method in toset(item.methods) :
              method => merge(
                {
                  "responses" = {
                    "200" = {
                      description = "Successful operation"
                      headers = {
                        "Access-Control-Allow-Origin" = { type = "string" }
                        "Set-Cookie" = { type = "string" }
                      }
                    }
                  }
                  "x-amazon-apigateway-integration" = merge(
                    {
                      uri        = item.uri
                      httpMethod = item.integ_method == "MATCH" ? upper(method) : item.integ_method
                      type       = item.type
                    },
                    item.type == "aws_proxy" ? {} : {
                      responses  = {
                        "default" = {
                          statusCode = "200"
                          responseParameters = {
                            "method.response.header.Access-Control-Allow-Origin" = ${originValue}
                          }
                          responseTemplates = {
                            "application/json" = "$input.body"
                          }
                        }
                      }
                    },
                    item.credentials != null ? { credentials = item.credentials } : {},
                    item.requestTemplates != null ? { requestTemplates = item.requestTemplates } : {},
                    item.integ_req_params != null ? { requestParameters = item.integ_req_params } : {}
                  )
                },
                item.parameters != null ? { parameters = item.parameters } : {},
                
                # ALTERA\xC7\xC3O CRUCIAL AQUI: Aplica a seguran\xE7a S\xD3 SE o m\xE9todo exigir
                contains(keys(item.method_auth), method) ? {
                  security = [
                    { (item.method_auth[method]) = [] }
                  ]
                } : {}
              )
              if method != "options"
            },
            item.enable_mock ? { "options" = ${mockBlock} } : {}
          )
          if item.path == path
        ]...)
      }
    }`;
}
__name(generateOpenapiSpecHcl, "generateOpenapiSpecHcl");
function handleAwsApiGatewayRestApi(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  self._apiRoles = {};
  self._createdRoles = /* @__PURE__ */ new Set();
  const targets = node.connections?.target ?? {};
  const openapiKeys = targets["cldmn_open_api"] ?? [];
  if (openapiKeys.length > 0) {
    const allExtractedRoutes = [];
    const allAuthConfigs = {};
    let globalCorsOrigin = "*";
    for (const openapiKey of openapiKeys) {
      const openapiNode = nodeMap[openapiKey];
      if (!openapiNode)
        continue;
      const params = openapiNode.cloudResource?.params ?? {};
      globalCorsOrigin = params["cors_allow_origin"] ?? globalCorsOrigin;
      const [routes, authConfig] = extractOpenapiData(self, node, openapiNode);
      allExtractedRoutes.push(...routes);
      if (authConfig)
        allAuthConfigs[authConfig["name"]] = authConfig;
    }
    const consolidatedRoutes = consolidateOpenapiRoutes(allExtractedRoutes);
    const apiName = node.logicalName ?? "MyAPI";
    let hclConfigList = "[\n";
    for (const config2 of consolidatedRoutes)
      hclConfigList += buildHclItem(config2);
    hclConfigList += "  ]";
    const dynamicSpecHcl = generateOpenapiSpecHcl(apiName, consolidatedRoutes, globalCorsOrigin, allAuthConfigs);
    if (!("_embedded_locals" in node))
      node["_embedded_locals"] = {};
    node["_embedded_locals"][`api_config_${apiName}`] = `__RAW__${hclConfigList}`;
    node["_embedded_locals"][`openapi_spec_${apiName}`] = `__RAW__${dynamicSpecHcl}`;
    node.cloudResource ??= {};
    node.cloudResource.params ??= {};
    node.cloudResource.params["body"] = `jsonencode(local.openapi_spec_${apiName})`;
    const createdRoles = self._createdRoles;
    if (createdRoles.size > 0) {
      node.cloudResource.params["depends_on"] = [...createdRoles].map((role) => `aws_iam_role.${role}`);
    }
  }
  return node;
}
__name(handleAwsApiGatewayRestApi, "handleAwsApiGatewayRestApi");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_api_gateway_rest_api() {
    return handleAwsApiGatewayRestApi(this);
  },
  handle_aws_api_gateway_resource() {
    return handleAwsApiGatewayResource(this);
  },
  handle_aws_api_gateway_method() {
    return handleAwsApiGatewayMethod(this);
  },
  handle_aws_api_gateway_integration() {
    return handleAwsApiGatewayIntegration(this);
  },
  handle_aws_api_gateway_deployment() {
    return handleAwsApiGatewayDeployment(this);
  },
  handle_aws_api_gateway_stage() {
    return handleAwsApiGatewayStage(this);
  },
  handle_aws_api_gateway_method_response() {
    return handleAwsApiGatewayMethodResponse(this);
  },
  handle_aws_api_gateway_integration_response() {
    return handleAwsApiGatewayIntegrationResponse(this);
  },
  handle_aws_api_gateway_account() {
    return handleAwsApiGatewayAccount(this);
  }
});

// src/handlers/k8sGlue.ts
var K8S_WORKLOAD_TYPES = /* @__PURE__ */ new Set(["kubernetes_deployment_v1", "kubernetes_stateful_set_v1", "kubernetes_pod_v1"]);
function k8sGlueSaName(workloadNode) {
  const raw = String(workloadNode.logicalName ?? "app");
  return `${raw}-sa`.replaceAll("_", "-").toLowerCase();
}
__name(k8sGlueSaName, "k8sGlueSaName");
function clusterNeedsPodEni(self, k8sClusterKey) {
  if (!k8sClusterKey)
    return false;
  const nodeMap = self.nodeMap ?? {};
  for (const n of self.nodes) {
    if (!K8S_WORKLOAD_TYPES.has(n.type))
      continue;
    if (!(n.connections?.target?.["cldmn_sg_rule"] ?? []).length)
      continue;
    const owner = findAncestorByType(n, "kubernetes_cluster_", nodeMap);
    if (owner && owner.key === k8sClusterKey)
      return true;
  }
  return false;
}
__name(clusterNeedsPodEni, "clusterNeedsPodEni");
function resolveEksFromK8sNode(self, k8sNode) {
  const nodeMap = self.nodeMap ?? {};
  const cluster = findAncestorByType(k8sNode, "kubernetes_cluster_", nodeMap);
  if (!cluster)
    return [null, null];
  const eksKeys = cluster.connections?.source?.["aws_eks_cluster"] ?? [];
  if (eksKeys.length === 0)
    return [null, null];
  const eksNode = nodeMap[eksKeys[0]];
  if (!eksNode)
    return [null, null];
  return [eksNode, eksNode.logicalName ?? null];
}
__name(resolveEksFromK8sNode, "resolveEksFromK8sNode");
function resolveK8sNamespaceNode(self, k8sNode) {
  const nodeMap = self.nodeMap ?? {};
  const nsKeys = k8sNode.connections?.target?.["kubernetes_namespace"] ?? [];
  if (nsKeys.length > 0) {
    const ns = nodeMap[nsKeys[0]];
    if (ns)
      return ns;
  }
  return findAncestorByType(k8sNode, "kubernetes_namespace", nodeMap);
}
__name(resolveK8sNamespaceNode, "resolveK8sNamespaceNode");
function nsRefOrLiteral(self, nsNode) {
  if (!nsNode)
    return "default";
  const nsName = String(nsNode.logicalName ?? "default");
  if (self.domainNodeKeys.includes(nsNode.key))
    return `\${kubernetes_namespace.${nsName}.metadata[0].name}`;
  return nsName;
}
__name(nsRefOrLiteral, "nsRefOrLiteral");
function k8sGluePairs(self, k8sNode, labelType) {
  const nodeMap = self.nodeMap ?? {};
  const pairs = [];
  const labelKeys = k8sNode.connections?.target?.[labelType] ?? [];
  for (const lk of labelKeys) {
    const labelNode = nodeMap[lk];
    if (!labelNode)
      continue;
    const labelTargets = labelNode.connections?.target ?? {};
    for (const [tType, tKeys] of Object.entries(labelTargets)) {
      if (!String(tType).startsWith("aws_"))
        continue;
      for (const tk of tKeys ?? []) {
        const awsNode = nodeMap[tk];
        if (awsNode)
          pairs.push([labelNode, awsNode]);
      }
    }
  }
  return pairs;
}
__name(k8sGluePairs, "k8sGluePairs");
function ensureIrsaForWorkload(self, k8sNode, statements, managedPolicies, nsNode, clusterLogicalName, eksNode, generated) {
  const workload = String(k8sNode.logicalName ?? "app");
  const roleLogicalName = `role_irsa_${workload}`.replaceAll("-", "_");
  const createdRoles = self._createdRoles ??= /* @__PURE__ */ new Set();
  if (createdRoles.has(roleLogicalName))
    return;
  createdRoles.add(roleLogicalName);
  const saName = k8sGlueSaName(k8sNode);
  const nsRef = nsRefOrLiteral(self, nsNode);
  const nsLiteral = nsNode ? String(nsNode.logicalName ?? "default") : "default";
  const oidcLogicalName = `eks_oidc_${clusterLogicalName}`;
  const clusterOwnedHere = eksNode ? self.domainNodeKeys.includes(eksNode.key) : false;
  let oidcArnRef;
  let oidcUrlRef;
  if (clusterOwnedHere) {
    oidcArnRef = `aws_iam_openid_connect_provider.${oidcLogicalName}.arn`;
    oidcUrlRef = `aws_iam_openid_connect_provider.${oidcLogicalName}.url`;
  } else {
    self.addGenericDataSource(generated, "aws_iam_openid_connect_provider", oidcLogicalName, {
      // aws_eks_cluster.X vira data.aws_eks_cluster.X sozinho (nó externo).
      url: `aws_eks_cluster.${clusterLogicalName}.identity[0].oidc[0].issuer`
    });
    oidcArnRef = `data.aws_iam_openid_connect_provider.${oidcLogicalName}.arn`;
    oidcUrlRef = `data.aws_iam_openid_connect_provider.${oidcLogicalName}.url`;
  }
  const oidcHost = `\${replace(${oidcUrlRef}, "https://", "")}`;
  const trustDoc = `doc_trust_${roleLogicalName}`;
  const trustNode = self.addGenericNode(generated, "aws_iam_policy_document", trustDoc);
  if (trustNode) {
    trustNode["_temp_data_source_definition"] = {
      XTYPE: "aws_iam_policy_document",
      logicalName: trustDoc,
      statement: [
        {
          effect: "Allow",
          actions: ["sts:AssumeRoleWithWebIdentity"],
          principals: [{ type: "Federated", identifiers: [oidcArnRef] }],
          condition: [
            { test: "StringEquals", variable: `${oidcHost}:sub`, values: [`system:serviceaccount:${nsLiteral}:${saName}`] },
            // Sem :aud qualquer SA do cluster poderia assumir a role.
            { test: "StringEquals", variable: `${oidcHost}:aud`, values: ["sts.amazonaws.com"] }
          ]
        }
      ]
    };
    trustNode.cloudResource.params = {};
  }
  const roleNode = self.addGenericNode(generated, "aws_iam_role", roleLogicalName);
  if (roleNode) {
    roleNode.cloudResource.params = {
      name: `irsa-${workload}`.slice(0, 64),
      assume_role_policy: `data.aws_iam_policy_document.${trustDoc}.json`
    };
  }
  if (statements.length > 0) {
    const permDoc = `doc_perm_${roleLogicalName}`;
    const permNode = self.addGenericNode(generated, "aws_iam_policy_document", permDoc);
    if (permNode) {
      permNode["_temp_data_source_definition"] = {
        XTYPE: "aws_iam_policy_document",
        logicalName: permDoc,
        statement: normalizeStatements(statements)
      };
      permNode.cloudResource.params = {};
    }
    const policyNode = self.addGenericNode(generated, "aws_iam_role_policy", `policy_${roleLogicalName}`);
    if (policyNode) {
      policyNode.cloudResource.params = {
        name: `irsa-${workload}-access`.slice(0, 64),
        role: `aws_iam_role.${roleLogicalName}.id`,
        policy: `data.aws_iam_policy_document.${permDoc}.json`
      };
    }
  }
  for (const mp of managedPolicies ?? []) {
    const cleanMp = String(mp).replace(/[^a-zA-Z0-9_]/g, "_");
    const attachNode = self.addGenericNode(generated, "aws_iam_role_policy_attachment", `${cleanMp}_to_${roleLogicalName}_attach`);
    if (attachNode) {
      attachNode.cloudResource.params = {
        role: `aws_iam_role.${roleLogicalName}.name`,
        policy_arn: `arn:aws:iam::aws:policy/${mp}`
      };
    }
  }
  const saNode = self.addGenericNode(generated, "kubernetes_manifest", `sa_${saName}`.replaceAll("-", "_"));
  if (saNode) {
    saNode.cloudResource.params = {
      manifest: {
        apiVersion: "v1",
        kind: "ServiceAccount",
        metadata: {
          name: saName,
          namespace: nsRef,
          annotations: { "eks.amazonaws.com/role-arn": `\${aws_iam_role.${roleLogicalName}.arn}` }
        }
      }
    };
  }
}
__name(ensureIrsaForWorkload, "ensureIrsaForWorkload");
function ensurePodSecurityGroup(self, k8sNode, ownedSgPairs, eksNode, nsNode, generated) {
  const workload = String(k8sNode.logicalName ?? "app");
  const sgLogicalName = `${workload}_pod_sg`.replaceAll("-", "_");
  const clusterLogicalName = eksNode.logicalName;
  const createdPodSgs = self._createdPodSgs ??= {};
  let sgNode = createdPodSgs[sgLogicalName];
  if (!sgNode) {
    const newSgNode = self.addGenericNode(generated, "aws_security_group", sgLogicalName);
    if (!newSgNode)
      return;
    sgNode = newSgNode;
    sgNode.cloudResource.params = {
      name: `${workload}-pod-sg`.slice(0, 255),
      description: `SG dos pods do workload ${workload} (SecurityGroupPolicy)`,
      vpc_id: `aws_eks_cluster.${clusterLogicalName}.vpc_config[0].vpc_id`,
      egress: [
        {
          from_port: 0,
          to_port: 0,
          protocol: "-1",
          cidr_blocks: ["0.0.0.0/0"],
          description: "Saida liberada (pod precisa de DNS/API/AWS)"
        }
      ]
    };
    createdPodSgs[sgLogicalName] = sgNode;
    const sgpNode = self.addGenericNode(generated, "kubernetes_manifest", `sgp_${sgLogicalName}`);
    if (sgpNode) {
      sgpNode.cloudResource.params = {
        manifest: {
          apiVersion: "vpcresources.k8s.aws/v1beta1",
          kind: "SecurityGroupPolicy",
          metadata: {
            name: `${workload}-sgp`.replaceAll("_", "-").toLowerCase(),
            namespace: nsRefOrLiteral(self, nsNode)
          },
          spec: {
            podSelector: { matchLabels: { "app.kubernetes.io/name": workload } },
            securityGroups: { groupIds: [`\${aws_security_group.${sgLogicalName}.id}`] }
          }
        }
      };
    }
  }
  for (const [labelNode, awsNode] of ownedSgPairs) {
    const targetSg = self.findAttachedSecurityGroup(awsNode, self.nodeMap ?? {});
    if (!targetSg) {
      self.collector.addError([
        "k8s_glue_target_no_sg",
        k8sNode.key,
        `'${workload}' acessa '${awsNode.logicalName}', mas nao foi possivel achar o Security Group do destino.`
      ]);
      continue;
    }
    self.createIngressRuleResource(labelNode, sgNode, targetSg, generated);
  }
}
__name(ensurePodSecurityGroup, "ensurePodSecurityGroup");
function isK8sGlueState(self) {
  const nodeMap = self.nodeMap ?? {};
  const tfNode = self.terraformKey ? nodeMap[self.terraformKey] : void 0;
  if (!tfNode)
    return false;
  const parent = tfNode.group ? nodeMap[tfNode.group] : void 0;
  return Boolean(parent && parent.type === "kubernetes_cluster_");
}
__name(isK8sGlueState, "isK8sGlueState");
function preprocessK8sAwsGlue(self) {
  const nodes = self.payload.nodes ?? [];
  self.nodes = nodes;
  const generated = [];
  if (!isK8sGlueState(self))
    return self.payload;
  for (const k8sNode of [...nodes]) {
    if (!K8S_WORKLOAD_TYPES.has(k8sNode.type))
      continue;
    const polPairs = k8sGluePairs(self, k8sNode, "cldmn_policy");
    const sgPairs = k8sGluePairs(self, k8sNode, "cldmn_sg_rule");
    if (polPairs.length === 0 && sgPairs.length === 0)
      continue;
    const workload = k8sNode.logicalName ?? "app";
    const [eksNode, clusterLogicalName] = resolveEksFromK8sNode(self, k8sNode);
    if (!eksNode) {
      self.collector.addError([
        "k8s_glue_no_cluster",
        k8sNode.key,
        `'${workload}' esta ligado a recursos AWS mas nao foi possivel resolver o cluster EKS (kubernetes_cluster_ -> aws_eks_cluster).`
      ]);
      continue;
    }
    const nsNode = resolveK8sNamespaceNode(self, k8sNode);
    if (polPairs.length > 0) {
      const statements = [];
      const managedPolicies = [];
      for (const [label, awsNode] of polPairs) {
        statements.push(...extractPolicyFromGraph(self, k8sNode, awsNode) ?? []);
        const mp = (label.cloudResource?.params ?? {})["managed_policy_"];
        if (mp && !managedPolicies.includes(mp))
          managedPolicies.push(mp);
      }
      if (statements.length > 0 || managedPolicies.length > 0) {
        ensureIrsaForWorkload(self, k8sNode, statements, managedPolicies, nsNode, clusterLogicalName, eksNode, generated);
      }
    }
    if (sgPairs.length > 0) {
      ensurePodSecurityGroup(self, k8sNode, sgPairs, eksNode, nsNode, generated);
    }
  }
  if (generated.length > 0) {
    nodes.push(...generated);
    for (const gen of generated) {
      if (self.nodeMap)
        self.nodeMap[gen.key] = gen;
      if (!self.domainNodeKeys.includes(gen.key))
        self.domainNodeKeys.push(gen.key);
    }
  }
  return self.payload;
}
__name(preprocessK8sAwsGlue, "preprocessK8sAwsGlue");
Object.assign(AwsProviderLogic.prototype, {
  preprocessK8sAwsGlue() {
    return preprocessK8sAwsGlue(this);
  }
});

// src/handlers/eks.ts
function addDynamicProvider(self, name, configParams, source, version2) {
  self.activeProviders.add(name);
  if (source || version2) {
    if (!(name in self.providerDefinitions))
      self.providerDefinitions[name] = {};
    if (source)
      self.providerDefinitions[name].source = source;
    if (version2)
      self.providerDefinitions[name].version = version2;
  }
  self.dynamicProviderConfigs[name] = configParams;
}
__name(addDynamicProvider, "addDynamicProvider");
function applyEksSubnetTags(subnetNode, clusterName) {
  if (!subnetNode || !clusterName)
    return;
  subnetNode.cloudResource ??= {};
  subnetNode.cloudResource.params ??= {};
  const params = subnetNode.cloudResource.params;
  if (!("tags" in params))
    params["tags"] = {};
  const tags = params["tags"];
  tags[`kubernetes.io/cluster/${clusterName}`] = "shared";
  const isPublic = subnetNode["is_public"] ?? false;
  const elbTag = isPublic ? "kubernetes.io/role/elb" : "kubernetes.io/role/internal-elb";
  tags[elbTag] = "1";
}
__name(applyEksSubnetTags, "applyEksSubnetTags");
function pyJsonDumpsSimple(obj) {
  if (obj === null || obj === void 0)
    return "null";
  if (typeof obj === "boolean")
    return obj ? "true" : "false";
  if (typeof obj === "number")
    return String(obj);
  if (typeof obj === "string")
    return JSON.stringify(obj);
  if (Array.isArray(obj))
    return "[" + obj.map(pyJsonDumpsSimple).join(", ") + "]";
  return "{" + Object.entries(obj).map(([k, v]) => `${JSON.stringify(k)}: ${pyJsonDumpsSimple(v)}`).join(", ") + "}";
}
__name(pyJsonDumpsSimple, "pyJsonDumpsSimple");
function ensureEksNetworkComponents(self, clusterNode, cniProvider) {
  const clusterLogicalName = clusterNode.logicalName;
  const clusterKey = clusterNode.key;
  const clusterRefName = `aws_eks_cluster.${clusterLogicalName}.name`;
  const clusterRefOidcIssuer = `aws_eks_cluster.${clusterLogicalName}.identity[0].oidc[0].issuer`;
  let k8sZeroTrust = false;
  const k8sConns = clusterNode.connections?.target?.["kubernetes_cluster_"] ?? [];
  if (k8sConns.length > 0) {
    const k8sClusterNode = self.nodeMap?.[k8sConns[0]];
    if (k8sClusterNode) {
      const zt = k8sClusterNode.cloudResource?.params?.["zeroTrust"];
      k8sZeroTrust = zt === void 0 ? true : Boolean(zt);
    }
  }
  const dataTlsLogicalName = `eks_tls_${clusterLogicalName}`;
  self.registerRequiredProvider("tls_certificate");
  self.addGenericDataSource(self.nodes, "tls_certificate", dataTlsLogicalName, { url: clusterRefOidcIssuer });
  const oidcProviderName = `eks_oidc_${clusterLogicalName}`;
  const thumbprintRef = `data.tls_certificate.${dataTlsLogicalName}.certificates[0].sha1_fingerprint`;
  const oidcNode = self.addGenericNode(self.generatedNodes, "aws_iam_openid_connect_provider", oidcProviderName, clusterNode, null);
  if (oidcNode) {
    oidcNode.cloudResource.params = {
      client_id_list: ["sts.amazonaws.com"],
      thumbprint_list: [thumbprintRef],
      url: clusterRefOidcIssuer
    };
    oidcNode.connections ??= {};
    oidcNode.connections.source = { aws_eks_cluster: [clusterKey] };
  }
  if (cniProvider === "cilium") {
    const helmCilium = self.addGenericNode(self.generatedNodes, "helm_release", `cilium_${clusterLogicalName}`, clusterNode, null);
    if (helmCilium) {
      helmCilium.cloudResource.params = {
        name: "cilium",
        repository: "https://helm.cilium.io/",
        chart: "cilium",
        namespace: "kube-system",
        set: [
          { name: "eni.enabled", value: "true" },
          { name: "ipam.mode", value: "eni" },
          { name: "egressGateway.enabled", value: "true" },
          { name: "cluster.name", value: clusterRefName },
          { name: "cluster.id", value: clusterRefName }
        ]
      };
      helmCilium.connections ??= {};
      helmCilium.connections.source = { aws_eks_cluster: [clusterKey] };
    }
  } else if (cniProvider === "calico") {
    const helmCalico = self.addGenericNode(self.generatedNodes, "helm_release", `calico_${clusterLogicalName}`, clusterNode, null);
    if (helmCalico) {
      helmCalico.cloudResource.params = {
        name: "calico",
        repository: "https://docs.tigera.io/calico/charts",
        chart: "tigera-operator",
        namespace: "tigera-operator",
        create_namespace: true,
        set: [{ name: "installation.kubernetesProvider", value: "EKS" }]
      };
      helmCalico.connections ??= {};
      helmCalico.connections.source = { aws_eks_cluster: [clusterKey] };
    }
  }
  const nodeGroupDependencies = [];
  for (const n of self.nodes) {
    if (n.type === "aws_eks_node_group") {
      const ngLogicalName = n.logicalName;
      if (ngLogicalName)
        nodeGroupDependencies.push(`aws_eks_node_group.${ngLogicalName}`);
    }
  }
  const eksAddons = ["coredns", "kube-proxy"];
  if (cniProvider !== "cilium" && cniProvider !== "calico")
    eksAddons.push("vpc-cni");
  for (const addon of eksAddons) {
    const logicalAddonName = addon.replaceAll("-", "_");
    const addonNode = self.addGenericNode(self.generatedNodes, "aws_eks_addon", `${logicalAddonName}_${clusterLogicalName}`, clusterNode, null);
    if (addonNode) {
      const addonParams = {
        cluster_name: clusterRefName,
        addon_name: addon,
        resolve_conflicts_on_create: "OVERWRITE",
        resolve_conflicts_on_update: "OVERWRITE"
      };
      if (addon === "vpc-cni") {
        const cniConfig = { env: { ENABLE_PREFIX_DELEGATION: "true", WARM_PREFIX_TARGET: "1" } };
        if (k8sZeroTrust)
          cniConfig["enableNetworkPolicy"] = "true";
        if (k8sConns.length > 0 && clusterNeedsPodEni(self, k8sConns[0])) {
          cniConfig["env"]["ENABLE_POD_ENI"] = "true";
          self.collector.addInfo([`EKS '${clusterLogicalName}': SG por pod detectado -- addon vpc-cni configurado com ENABLE_POD_ENI.`, clusterKey]);
        }
        addonParams["configuration_values"] = `jsonencode(${pyJsonDumpsSimple(cniConfig)})`;
      }
      if (nodeGroupDependencies.length > 0)
        addonParams["depends_on"] = nodeGroupDependencies;
      addonNode.cloudResource.params = addonParams;
      addonNode.connections ??= {};
      addonNode.connections.source = { aws_eks_cluster: [clusterKey] };
    }
  }
  const k8sAuthConfig = {
    host: `aws_eks_cluster.${clusterLogicalName}.endpoint`,
    cluster_ca_certificate: `base64decode(aws_eks_cluster.${clusterLogicalName}.certificate_authority[0].data)`,
    exec: {
      api_version: "client.authentication.k8s.io/v1beta1",
      args: ["eks", "get-token", "--cluster-name", `aws_eks_cluster.${clusterLogicalName}.name`],
      command: "aws"
    }
  };
  const helmConfig = { kubernetes: k8sAuthConfig };
  addDynamicProvider(self, "helm", helmConfig);
  addDynamicProvider(self, "kubernetes", k8sAuthConfig);
}
__name(ensureEksNetworkComponents, "ensureEksNetworkComponents");
function handleAwsEksCluster(self) {
  const node = self.node;
  const roleKeys = node.connections?.source?.["aws_iam_role"] ?? [];
  if (roleKeys.length > 0) {
    const roleNode = self.nodeMap?.[roleKeys[0]];
    if (roleNode) {
      self.addManagedPolicy(node, "AmazonEKSClusterPolicy", self.nodeMap ?? {});
    }
  }
  const clusterName = node.logicalName;
  const tagKey = `kubernetes.io/cluster/${clusterName}`;
  const subnetKeys = node.connections?.target?.["aws_subnet"] ?? [];
  for (const subKey of subnetKeys) {
    const subnetNode = self.nodeMap?.[subKey];
    if (subnetNode) {
      const p = subnetNode.cloudResource.params;
      if (!("tags" in p))
        p["tags"] = {};
      p["tags"][tagKey] = "shared";
    }
  }
  const cniProvider = node.cloudResource?.params?.["cni_provider_"] ?? "aws_native";
  ensureEksNetworkComponents(self, node, cniProvider);
}
__name(handleAwsEksCluster, "handleAwsEksCluster");
function ensureEksNodeSgRules(self, nodeGroupNode, clusterNode, sgNode) {
  const ngLogical = nodeGroupNode.logicalName;
  const clusterLogical = clusterNode.logicalName;
  const sgLogical = sgNode.logicalName;
  const nodeSgId = `aws_security_group.${sgLogical}.id`;
  const clusterSgId = `aws_eks_cluster.${clusterLogical}.vpc_config[0].cluster_security_group_id`;
  const rulesToCreate = [
    { suffix: "ingress_cluster_to_node_kubelet", type: "ingress", from_port: 10250, to_port: 10250, protocol: "tcp", desc: "Allow Control Plane to Kubelet (logs/exec)", source_sg: clusterSgId },
    { suffix: "ingress_cluster_to_node_webhooks", type: "ingress", from_port: 9443, to_port: 9443, protocol: "tcp", desc: "Allow Control Plane to Node Webhooks (LB Controller, etc)", source_sg: clusterSgId },
    { suffix: "ingress_node_to_node_all", type: "ingress", from_port: 0, to_port: 0, protocol: "-1", desc: "Allow Nodes to communicate with each other", source_sg: nodeSgId },
    { suffix: "ingress_cluster_to_node_dns_udp", type: "ingress", from_port: 53, to_port: 53, protocol: "udp", desc: "Allow Control Plane to DNS pods (UDP)", source_sg: clusterSgId },
    { suffix: "ingress_cluster_to_node_dns_tcp", type: "ingress", from_port: 53, to_port: 53, protocol: "tcp", desc: "Allow Control Plane to DNS pods (TCP)", source_sg: clusterSgId }
  ];
  for (const rule of rulesToCreate) {
    const ruleName = `rule_${ngLogical}_${rule.suffix}`;
    const newRule = self.addGenericNode(self.generatedNodes, "aws_security_group_rule", ruleName, nodeGroupNode, null);
    if (newRule) {
      newRule.cloudResource.params = {
        type: rule.type,
        from_port: rule.from_port,
        to_port: rule.to_port,
        protocol: rule.protocol,
        description: rule.desc,
        security_group_id: nodeSgId,
        source_security_group_id: rule.source_sg
      };
    }
  }
}
__name(ensureEksNodeSgRules, "ensureEksNodeSgRules");
function handleAwsEksNodeGroup(self) {
  const node = self.node;
  const roleKeys = node.connections?.source?.["aws_iam_role"] ?? [];
  if (roleKeys.length > 0) {
    const roleNode = self.nodeMap?.[roleKeys[0]];
    if (roleNode) {
      const requiredPolicies = ["AmazonEKSWorkerNodePolicy", "AmazonEKS_CNI_Policy", "AmazonEC2ContainerRegistryReadOnly"];
      for (const policy of requiredPolicies)
        self.addManagedPolicy(node, policy, self.nodeMap ?? {});
    }
  }
  const sourceConns = node.connections?.source ?? {};
  const targetConns = node.connections?.target ?? {};
  let clusterName = "unknown";
  const clusterKeys = sourceConns["aws_eks_cluster"] ?? [];
  if (clusterKeys.length > 0) {
    const clusterNode = self.nodeMap?.[clusterKeys[0]];
    if (clusterNode)
      clusterName = clusterNode.logicalName ?? "unknown";
  }
  if (clusterName !== "unknown") {
    const subnetKeys = targetConns["aws_subnet"] ?? [];
    for (const subKey of subnetKeys) {
      const subnetNode = self.nodeMap?.[subKey];
      if (subnetNode)
        applyEksSubnetTags(subnetNode, clusterName);
    }
  }
  const sgKeys = sourceConns["aws_security_group"] ?? [];
  if (clusterKeys.length > 0 && sgKeys.length > 0) {
    const clusterNode = self.nodeMap?.[clusterKeys[0]];
    const sgNode = self.nodeMap?.[sgKeys[0]];
    if (clusterNode && sgNode)
      ensureEksNodeSgRules(self, node, clusterNode, sgNode);
  }
}
__name(handleAwsEksNodeGroup, "handleAwsEksNodeGroup");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_eks_cluster() {
    return handleAwsEksCluster(this);
  },
  handle_aws_eks_node_group() {
    return handleAwsEksNodeGroup(this);
  }
});

// src/handlers/storage.ts
function pyFloatStr(x) {
  return Number.isInteger(x) ? `${x}.0` : String(x);
}
__name(pyFloatStr, "pyFloatStr");
function handleAwsEfsFileSystem(self) {
  const node = self.node;
  const efsLogicalName = node.logicalName;
  const efsParams = node.cloudResource?.params ?? {};
  const networkCtx = self.getConnectedNetworkContext(node, self.nodeMap ?? {});
  const subnetNodes = networkCtx.subnet_nodes;
  const azNames = networkCtx.az_names;
  if (azNames.length === 1)
    efsParams["availability_zone_name"] = azNames[0];
  else
    delete efsParams["availability_zone_name"];
  const sgKeys = node.connections?.source?.["aws_security_group"] ?? [];
  const sgIds = [];
  for (const sgKey of sgKeys) {
    const sgNode = self.nodeMap?.[sgKey];
    if (sgNode)
      sgIds.push(`aws_security_group.${sgNode.logicalName}.id`);
  }
  for (const subnetNode of subnetNodes) {
    const subnetLogicalName = subnetNode.logicalName;
    const mtLogicalName = `mt_${efsLogicalName}_${subnetLogicalName}`;
    const newMtNode = self.addGenericNode(self.generatedNodes, "aws_efs_mount_target", mtLogicalName, node, null);
    if (newMtNode) {
      const params = newMtNode.cloudResource.params;
      params["file_system_id"] = `aws_efs_file_system.${efsLogicalName}.id`;
      params["subnet_id"] = `aws_subnet.${subnetLogicalName}.id`;
      if (sgIds.length > 0)
        params["security_groups"] = sgIds;
      newMtNode.connections ??= { source: {}, target: {} };
      if (!("target" in newMtNode.connections))
        newMtNode.connections.target = {};
    }
  }
}
__name(handleAwsEfsFileSystem, "handleAwsEfsFileSystem");
function handleAwsS3Object(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const rawFilePath = String(params["source"] ?? "").trim();
  if (!rawFilePath)
    return;
  const connections = node.connections?.source ?? {};
  const githubKeys = connections["cldmn_github"] ?? [];
  const hasGithubSource = githubKeys.length > 0;
  let finalSourcePath = rawFilePath;
  const cleanPath = normalizePath(rawFilePath);
  if (hasGithubSource) {
    const githubNode = self.nodeMap?.[githubKeys[0]];
    if (githubNode) {
      const ghParams = githubNode.cloudResource?.params ?? {};
      const githubRepo = ghParams["github_repository"] ?? "";
      const basePath = `\${path.module}/.external_modules/${githubRepo}/${cleanPath}`;
      finalSourcePath = basePath.replaceAll("//", "/");
    }
  } else {
    if (!rawFilePath.startsWith("${") && !rawFilePath.startsWith("/"))
      finalSourcePath = `\${path.module}/${cleanPath}`;
    else
      finalSourcePath = rawFilePath.replaceAll("\\", "/");
  }
  params["source"] = finalSourcePath;
  if (!params["etag"])
    params["etag"] = `filemd5("${finalSourcePath}")`;
  const bucketKeys = node.connections?.target?.["aws_s3_bucket"] ?? [];
  const bucketNode = bucketKeys.length > 0 ? self.nodeMap?.[bucketKeys[0]] : null;
  let isEnforced = false;
  if (bucketNode) {
    const ownershipKeys = bucketNode.connections?.source?.["aws_s3_bucket_ownership_controls"] ?? [];
    if (ownershipKeys.length > 0) {
      const ownershipNode = self.nodeMap?.[ownershipKeys[0]];
      const ownershipParams = ownershipNode?.cloudResource?.params ?? {};
      const rules = ownershipParams["rule"] ?? [];
      if (Array.isArray(rules) && rules.length > 0 && rules[0]["object_ownership"] === "BucketOwnerEnforced")
        isEnforced = true;
    }
  }
  if (isEnforced && "acl" in params)
    delete params["acl"];
  let isLockEnabled = false;
  if (bucketNode) {
    const bucketParams = bucketNode.cloudResource?.params ?? {};
    isLockEnabled = String(bucketParams["object_lock_enabled"] ?? false).toLowerCase() === "true";
  }
  if (!isLockEnabled) {
    delete params["object_lock_mode"];
    delete params["object_lock_retain_until_date"];
    delete params["object_lock_legal_hold_status"];
  }
}
__name(handleAwsS3Object, "handleAwsS3Object");
var DYNAMO_SCALING_CONFIGS = [
  { type: "Read", mode_key: "autoscaling_read_mode_", min_key: "autoscaling_read_min_", max_key: "autoscaling_read_max_", target_key: "autoscaling_read_target_", metric_type: "DynamoDBReadCapacityUtilization", ignore_attr: "read_capacity" },
  { type: "Write", mode_key: "autoscaling_write_mode_", min_key: "autoscaling_write_min_", max_key: "autoscaling_write_max_", target_key: "autoscaling_write_target_", metric_type: "DynamoDBWriteCapacityUtilization", ignore_attr: "write_capacity" }
];
function ensureLifecycleIgnore(params, newAttributes) {
  if (!("lifecycle" in params))
    params["lifecycle"] = [];
  let lifecycleBlock;
  if (Array.isArray(params["lifecycle"])) {
    if (params["lifecycle"].length === 0)
      params["lifecycle"].push({});
    lifecycleBlock = params["lifecycle"][0];
  } else if (params["lifecycle"] && typeof params["lifecycle"] === "object") {
    lifecycleBlock = params["lifecycle"];
  } else {
    params["lifecycle"] = [{}];
    lifecycleBlock = params["lifecycle"][0];
  }
  let currentIgnores = lifecycleBlock["ignore_changes"] ?? [];
  if (!Array.isArray(currentIgnores))
    currentIgnores = currentIgnores ? [currentIgnores] : [];
  const finalSet = /* @__PURE__ */ new Set([...currentIgnores, ...newAttributes]);
  lifecycleBlock["ignore_changes"] = [...finalSet];
}
__name(ensureLifecycleIgnore, "ensureLifecycleIgnore");
function createDynamodbScalingResources(self, tableNode, valuesDict, config2, indexName) {
  const tableLogicalName = tableNode.logicalName;
  const scaleType = config2.type;
  let suffix;
  let resourceId;
  let scalableDimension;
  if (indexName) {
    suffix = `${scaleType}_${indexName}_${tableLogicalName}`;
    resourceId = `table/\${aws_dynamodb_table.${tableLogicalName}.name}/index/${indexName}`;
    scalableDimension = `dynamodb:index:${scaleType}CapacityUnits`;
  } else {
    suffix = `${scaleType}_${tableLogicalName}`;
    resourceId = `table/\${aws_dynamodb_table.${tableLogicalName}.name}`;
    scalableDimension = `dynamodb:table:${scaleType}CapacityUnits`;
  }
  const targetLogicalName = `sc_target_${suffix}`;
  const policyLogicalName = `sc_policy_${suffix}`;
  const minCap = valuesDict[config2.min_key] ?? 1;
  const maxCap = valuesDict[config2.max_key] ?? 10;
  const targetValue = valuesDict[config2.target_key] ?? 70;
  const newTargetNode = self.addGenericNode(self.generatedNodes, "aws_appautoscaling_target", targetLogicalName, null, null);
  if (newTargetNode) {
    const targetParams = newTargetNode.cloudResource.params;
    targetParams["max_capacity"] = parseInt(String(maxCap), 10);
    targetParams["min_capacity"] = parseInt(String(minCap), 10);
    targetParams["resource_id"] = resourceId;
    targetParams["scalable_dimension"] = scalableDimension;
    targetParams["service_namespace"] = "dynamodb";
    newTargetNode.connections = { source: {}, target: { aws_dynamodb_table: [tableNode.key] } };
  }
  const newPolicyNode = self.addGenericNode(self.generatedNodes, "aws_appautoscaling_policy", policyLogicalName, null, null);
  if (newPolicyNode) {
    const policyParams = newPolicyNode.cloudResource.params;
    policyParams["name"] = `DynamoDB${scaleType}CapacityUtilization:${targetLogicalName}`;
    policyParams["policy_type"] = "TargetTrackingScaling";
    policyParams["resource_id"] = `aws_appautoscaling_target.${targetLogicalName}.resource_id`;
    policyParams["scalable_dimension"] = `aws_appautoscaling_target.${targetLogicalName}.scalable_dimension`;
    policyParams["service_namespace"] = `aws_appautoscaling_target.${targetLogicalName}.service_namespace`;
    policyParams["target_tracking_scaling_policy_configuration"] = [
      {
        predefined_metric_specification: [{ predefined_metric_type: config2.metric_type }],
        // Python float(target_value) -> renderiza com ".0"; __RAW__ p/ sair sem aspas.
        target_value: `__RAW__${pyFloatStr(parseFloat(String(targetValue)))}`
      }
    ];
    newPolicyNode.connections = { source: {}, target: { aws_appautoscaling_target: [newTargetNode.key] } };
  }
}
__name(createDynamodbScalingResources, "createDynamodbScalingResources");
function processEntityScaling(self, node, valuesDict, scalingConfigs, indexName) {
  const attributesToIgnore = [];
  let countCreated = 0;
  for (const config2 of scalingConfigs) {
    const mode = valuesDict[config2.mode_key];
    if (mode && String(mode).trim() === "AUTOSCALE") {
      createDynamodbScalingResources(self, node, valuesDict, config2, indexName);
      countCreated += 1;
      attributesToIgnore.push(config2.ignore_attr);
    }
  }
  if (attributesToIgnore.length > 0)
    ensureLifecycleIgnore(valuesDict, attributesToIgnore);
  return countCreated;
}
__name(processEntityScaling, "processEntityScaling");
function handleAwsDynamodbTable(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const billingMode = params["billing_mode"] ?? "PROVISIONED";
  if (billingMode !== "PROVISIONED")
    return;
  processEntityScaling(self, node, params, DYNAMO_SCALING_CONFIGS, null);
  const gsis = params["global_secondary_index"] ?? [];
  if (Array.isArray(gsis) && gsis.length > 0) {
    for (const gsi of gsis) {
      const indexName = gsi["name"];
      if (indexName)
        processEntityScaling(self, node, gsi, DYNAMO_SCALING_CONFIGS, indexName);
    }
  }
}
__name(handleAwsDynamodbTable, "handleAwsDynamodbTable");
function handleAwsS3BucketReplicationConfiguration(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const conns = node.connections ?? {};
  const srcKeys = conns.source?.["aws_s3_bucket"] ?? [];
  const tgtKeys = conns.target?.["aws_s3_bucket"] ?? [];
  const srcNode = srcKeys.length > 0 ? self.nodeMap?.[srcKeys[0]] : null;
  const tgtNode = tgtKeys.length > 0 ? self.nodeMap?.[tgtKeys[0]] : null;
  const srcName = srcNode ? srcNode.logicalName : "source";
  const tgtName = tgtNode ? tgtNode.logicalName : "target";
  const srcArn = srcNode ? `aws_s3_bucket.${srcName}.arn` : "";
  const tgtArn = tgtNode ? `aws_s3_bucket.${tgtName}.arn` : "";
  const rules = params["rule"] ?? [];
  if (srcNode && tgtNode) {
    const [srcAcc] = findAccountAndRegionName(srcNode, self.nodeMap ?? {});
    const [tgtAcc] = findAccountAndRegionName(tgtNode, self.nodeMap ?? {});
    if (srcAcc && tgtAcc && srcAcc !== tgtAcc) {
      for (const r of rules) {
        if (r && typeof r === "object" && "destination" in r) {
          const dest = Array.isArray(r["destination"]) ? r["destination"][0] : r["destination"];
          dest["account"] = tgtAcc;
        }
      }
    } else if (srcAcc === tgtAcc) {
      for (const r of rules) {
        if (r && typeof r === "object" && "destination" in r) {
          const dest = Array.isArray(r["destination"]) ? r["destination"][0] : r["destination"];
          delete dest["account"];
          delete dest["access_control_translation"];
        }
      }
    }
  }
  for (const r of rules) {
    if (r && typeof r === "object" && "filter" in r) {
      const filters = Array.isArray(r["filter"]) ? r["filter"] : [r["filter"]];
      for (const f of filters) {
        if (f && typeof f === "object") {
          const rawPrefix = f["prefix"];
          const hasPrefix = rawPrefix !== null && rawPrefix !== void 0 && String(rawPrefix).trim() !== "";
          const hasTags = "tags" in f && Boolean(f["tags"]) && Object.keys(f["tags"] ?? {}).length > 0;
          const hasTagBlock = "tag" in f && Array.isArray(f["tag"]) && f["tag"].length > 0;
          if (!hasPrefix && "prefix" in f)
            delete f["prefix"];
          if ("and" in f) {
            const andVal = f["and"];
            if (!andVal || Array.isArray(andVal) && andVal.length > 0 && !andVal[0]["prefix"] && !andVal[0]["tags"])
              delete f["and"];
          }
          if (hasPrefix && (hasTags || hasTagBlock)) {
            const andBlock = { prefix: f["prefix"] };
            delete f["prefix"];
            if (hasTags) {
              andBlock["tags"] = f["tags"];
              delete f["tags"];
            } else if (hasTagBlock) {
              const tagVal = f["tag"];
              delete f["tag"];
              if (Array.isArray(tagVal) && tagVal.length > 0 && tagVal[0] && typeof tagVal[0] === "object" && "key" in tagVal[0]) {
                const t = {};
                for (const item of tagVal)
                  t[item["key"]] = item["value"];
                andBlock["tags"] = t;
              } else {
                andBlock["tags"] = tagVal;
              }
            }
            f["and"] = [andBlock];
          }
        }
      }
    }
  }
  const roleKeys = conns.source?.["aws_iam_role"] ?? [];
  const roleNode = roleKeys.length > 0 ? self.nodeMap?.[roleKeys[0]] : null;
  const roleLn = roleNode ? roleNode.logicalName ?? "" : "";
  if (roleLn)
    params["role"] = `aws_iam_role.${roleLn}.arn`;
  if (srcArn && tgtArn && roleLn) {
    const srcHcl = String(srcName).replaceAll("-", "_");
    const tgtHcl = String(tgtName).replaceAll("-", "_");
    const nameSuffixHcl = `replication_from_${srcHcl}_to_${tgtHcl}`;
    const nameSuffixAttr = `replication-from-${srcName}-to-${tgtName}`;
    const polLn = `policy_${nameSuffixHcl}`;
    const polDict = {
      Version: "2012-10-17",
      Statement: [
        { Action: ["s3:GetReplicationConfiguration", "s3:ListBucket"], Effect: "Allow", Resource: [`\${${srcArn}}`] },
        { Action: ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"], Effect: "Allow", Resource: [`\${${srcArn}}/*`] },
        { Action: ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"], Effect: "Allow", Resource: [`\${${tgtArn}}/*`] }
      ]
    };
    const polJson = JSON.stringify(polDict, null, 2);
    const polNode = self.addGenericNode(self.generatedNodes, "aws_iam_policy", polLn, node, roleNode);
    if (polNode)
      polNode.cloudResource.params = { name: `s3-repl-policy-${nameSuffixAttr}`, policy: `jsonencode(${polJson})` };
    const attNode = self.addGenericNode(self.generatedNodes, "aws_iam_role_policy_attachment", `attach_${nameSuffixHcl}`, node, roleNode);
    if (attNode)
      attNode.cloudResource.params = { role: `aws_iam_role.${roleLn}.name`, policy_arn: `aws_iam_policy.${polLn}.arn` };
  }
}
__name(handleAwsS3BucketReplicationConfiguration, "handleAwsS3BucketReplicationConfiguration");
function createIamRole(self, parentNode, roleLogicalName, principalService) {
  const roleNode = self.addGenericNode(self.generatedNodes, "aws_iam_role", roleLogicalName, null, parentNode);
  if (roleNode) {
    const assumeRolePolicy = `jsonencode({
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "${principalService}"
      }
    }
  ]
})`;
    const p = roleNode.cloudResource.params;
    p["name"] = roleLogicalName;
    p["assume_role_policy"] = assumeRolePolicy;
    return roleNode;
  }
  return null;
}
__name(createIamRole, "createIamRole");
function processDbSubnetGroupAndAz(dbNode) {
  const dbParams = dbNode.cloudResource?.params ?? {};
  const piRetention = dbParams["performance_insights_retention_period"] ?? 0;
  const parsed = parseInt(String(piRetention), 10);
  const piRetentionInt = Number.isNaN(parsed) ? 0 : parsed;
  if (piRetentionInt > 0) {
    dbParams["performance_insights_enabled"] = true;
  } else {
    dbParams["performance_insights_enabled"] = "";
    dbParams["performance_insights_retention_period"] = "";
  }
}
__name(processDbSubnetGroupAndAz, "processDbSubnetGroupAndAz");
function handleRdsManagedSecretPolicy(self, dbNode) {
  const dbLogicalName = dbNode.logicalName ?? "Database";
  const dbParams = dbNode.cloudResource?.params ?? {};
  const managePassword = dbParams["manage_master_user_password"] ?? false;
  if (String(managePassword).toLowerCase() !== "true")
    return;
  const targetComputeTypes = ["aws_instance", "aws_lambda_function", "aws_ecs_task_definition", "aws_ecs_service", "cldmn_container", "aws_autoscaling_group"];
  const connectedKeys = /* @__PURE__ */ new Set();
  for (const direction of ["source", "target"]) {
    const directionConns = dbNode.connections?.[direction] ?? {};
    for (const [rType, keys] of Object.entries(directionConns)) {
      if (targetComputeTypes.includes(rType))
        for (const k of keys)
          connectedKeys.add(k);
    }
  }
  if (connectedKeys.size === 0)
    return;
  const sidValue = `AllowRDSSecretAccess_${dbLogicalName}`;
  const secretArnRef = `\${aws_db_instance.${dbLogicalName}.master_user_secret[0].secret_arn}`;
  const statements = [{ Sid: sidValue, Effect: "Allow", Action: ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource: secretArnRef }];
  for (const sourceKey of connectedKeys) {
    const sourceNode = self.nodeMap?.[sourceKey];
    if (!sourceNode)
      continue;
    const sourceType = sourceNode.type;
    const metadataOverride = sourceType && ["aws_ecs_task_definition", "aws_ecs_service", "cldmn_container"].includes(sourceType) ? { role_index: 1 } : null;
    const targetDict = sourceNode.connections?.target ?? {};
    const policiesBefore = /* @__PURE__ */ new Set([...targetDict["aws_iam_policy"] ?? [], ...targetDict["cldmn_policy"] ?? []]);
    self.createDynamicPolicy(sourceNode, `RDS_SecretAccess_${dbLogicalName}`, statements);
    const targetDictAfter = sourceNode.connections?.target ?? {};
    const policiesAfter = [...targetDictAfter["aws_iam_policy"] ?? [], ...targetDictAfter["cldmn_policy"] ?? []];
    const newPolicies = policiesAfter.filter((p) => !policiesBefore.has(p));
    if (metadataOverride) {
      for (const pId of newPolicies) {
        const pNode = self.nodeMap?.[pId];
        if (pNode)
          pNode["_internal_metadata"] = metadataOverride;
      }
    }
  }
}
__name(handleRdsManagedSecretPolicy, "handleRdsManagedSecretPolicy");
function handleRdsLogs(self, dbNode) {
  const targets = dbNode.connections?.target ?? {};
  const cwGroupKeys = targets["aws_cloudwatch_log_group"] ?? [];
  const dbParams = dbNode.cloudResource?.params ?? {};
  const logsInfo = dbParams["logs_"] ?? [];
  const rdsIdentifier = dbParams["identifier"] ?? dbNode.logicalName ?? "db";
  let hasMonitoring = false;
  const standardLogs = /* @__PURE__ */ new Set();
  const cwReferences = [];
  logsInfo.forEach((logEntry, index) => {
    const logTypeRaw = String(logEntry["log_type_"] ?? logEntry["logType"] ?? "").trim();
    const logType = logTypeRaw.toLowerCase();
    if (!logType)
      return;
    let awsLogPath;
    if (logType === "monitoring") {
      hasMonitoring = true;
      awsLogPath = "RDSOSMetrics";
    } else {
      standardLogs.add(logType);
      awsLogPath = `/aws/rds/instance/${rdsIdentifier}/${logType}`;
    }
    if (index < cwGroupKeys.length) {
      const cwNode = self.nodeMap?.[cwGroupKeys[index]];
      if (cwNode) {
        cwNode.cloudResource.params["name"] = awsLogPath;
        const cwLogicalName = cwNode.logicalName;
        if (cwLogicalName) {
          const cwRef = `aws_cloudwatch_log_group.${cwLogicalName}`;
          if (!cwReferences.includes(cwRef))
            cwReferences.push(cwRef);
        }
      }
    }
  });
  if (hasMonitoring) {
    const dbLogicalName = dbNode.logicalName ?? "db";
    const roleLogicalName = `role_monitoring_${dbLogicalName}`;
    const roleNode = createIamRole(self, dbNode, roleLogicalName, "monitoring.rds.amazonaws.com");
    if (roleNode) {
      dbParams["monitoring_role_arn"] = `aws_iam_role.${roleLogicalName}.arn`;
      const mi = dbParams["monitoring_interval"];
      if (!mi || parseInt(String(mi), 10) === 0)
        dbParams["monitoring_interval"] = 60;
      self.addManagedPolicy(dbNode, "service-role/AmazonRDSEnhancedMonitoringRole", self.nodeMap ?? {});
    }
  }
  if (standardLogs.size > 0)
    dbParams["enabled_cloudwatch_logs_exports"] = [...standardLogs];
  if (cwReferences.length > 0) {
    if (!("depends_on" in dbParams))
      dbParams["depends_on"] = [];
    if (Array.isArray(dbParams["depends_on"])) {
      for (const ref of cwReferences)
        if (!dbParams["depends_on"].includes(ref))
          dbParams["depends_on"].push(ref);
    }
  }
}
__name(handleRdsLogs, "handleRdsLogs");
function handleAwsDbInstance(self) {
  const node = self.node;
  processDbSubnetGroupAndAz(node);
  handleRdsManagedSecretPolicy(self, node);
  handleRdsLogs(self, node);
  const connections = node.connections?.source ?? {};
  const secretVersionKeys = connections["aws_secretsmanager_secret_version"] ?? [];
  const params = node.cloudResource?.params ?? {};
  if (secretVersionKeys.length > 0) {
    const svNode = self.nodeMap?.[secretVersionKeys[0]];
    if (svNode) {
      const svLogicalName = svNode.logicalName;
      if (svLogicalName) {
        params["username"] = `jsondecode(aws_secretsmanager_secret_version.${svLogicalName}.secret_string)["username"]`;
        params["password"] = `jsondecode(aws_secretsmanager_secret_version.${svLogicalName}.secret_string)["password"]`;
        if ("password_wo" in params)
          params["password_wo"] = "";
      }
    }
  }
  const targetConnections = node.connections?.target ?? {};
  if ("aws_db_snapshot" in targetConnections)
    params["skip_final_snapshot"] = "false";
}
__name(handleAwsDbInstance, "handleAwsDbInstance");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_efs_file_system() {
    return handleAwsEfsFileSystem(this);
  },
  handle_aws_s3_object() {
    return handleAwsS3Object(this);
  },
  handle_aws_dynamodb_table() {
    return handleAwsDynamodbTable(this);
  },
  handle_aws_s3_bucket_replication_configuration() {
    return handleAwsS3BucketReplicationConfiguration(this);
  },
  handle_aws_db_instance() {
    return handleAwsDbInstance(this);
  }
});

// src/handlers/iam.ts
function actionsForPermission(resourcePolicies, permissionLevel) {
  const actions = /* @__PURE__ */ new Set();
  if (permissionLevel === "Admin") {
    for (const acts of Object.values(resourcePolicies))
      for (const a of acts)
        actions.add(a);
  } else if (permissionLevel === "Write") {
    for (const a of resourcePolicies["Write"] ?? [])
      actions.add(a);
    for (const a of resourcePolicies["Read"] ?? [])
      actions.add(a);
    for (const a of resourcePolicies["List"] ?? [])
      actions.add(a);
  } else if (permissionLevel === "Read") {
    for (const a of resourcePolicies["Read"] ?? [])
      actions.add(a);
    for (const a of resourcePolicies["List"] ?? [])
      actions.add(a);
  } else {
    return null;
  }
  if (actions.size === 0)
    return null;
  return [...actions].sort();
}
__name(actionsForPermission, "actionsForPermission");
function jsonDumpsIndent2(obj) {
  return JSON.stringify(obj, null, 2);
}
__name(jsonDumpsIndent2, "jsonDumpsIndent2");
function handleAwsIamRole(self) {
  const node = self.node;
  const grants = node["grants"] ?? [];
  if (grants.length === 0)
    return;
  const params = node.cloudResource?.params ?? {};
  const roleLogicalName = node.logicalName || params["name"] || "default_role";
  const roleKey = node.key;
  const policiesDict = self.payload["policies"] ?? {};
  const domainKeys = self.payload.domainNodeKeys ?? [];
  const oidcConfig = node["cognitoOidcConfig"];
  const providerKey = "cognito_provider_implicit";
  const providerAlreadyCreated = domainKeys.includes(providerKey);
  if (oidcConfig && !providerAlreadyCreated) {
    const oidcProviderNode = {
      key: providerKey,
      type: "aws_iam_openid_connect_provider",
      logicalName: "cognito_provider",
      group: node["group"],
      cloudResource: {
        uiState: {},
        params: {
          url: oidcConfig["issuerUrl"],
          client_id_list: oidcConfig["audience"] ? [oidcConfig["audience"]] : []
        }
      },
      __isImplicit: true
    };
    if (!domainKeys.includes(providerKey)) {
      domainKeys.push(providerKey);
      self.payload.domainNodeKeys = domainKeys;
    }
    self.generatedNodes.push(oidcProviderNode);
  }
  grants.forEach((grant, grantIndex) => {
    const connectionKey = grant["connectionKey"];
    const resourcesList = grant["resources"] ?? [];
    if (!connectionKey || resourcesList.length === 0)
      return;
    const statements = [];
    for (const res of resourcesList) {
      const targetType = res["type"];
      const targetLogicalName = res["logicalName"];
      const permissionLevel = res["permission"];
      if (!targetType || !targetLogicalName)
        continue;
      if (!(targetType in policiesDict))
        continue;
      const actions = actionsForPermission(policiesDict[targetType], permissionLevel);
      if (!actions)
        continue;
      statements.push({ Effect: "Allow", Action: actions, Resource: [`\${${targetType}.${targetLogicalName}.arn}`] });
    }
    if (statements.length === 0)
      return;
    const policyDict = { Version: "2012-10-17", Statement: statements };
    const policyNodeKey = `${roleKey}_grant_${connectionKey}`;
    const policyLogicalName = `policy_${roleLogicalName}_${grantIndex}`;
    const iamRolePolicyNode = {
      key: policyNodeKey,
      type: "aws_iam_role_policy",
      logicalName: policyLogicalName,
      group: node["group"],
      cloudResource: {
        uiState: {},
        params: {
          name: `${roleLogicalName}-grant-${grantIndex}`,
          role: `\${aws_iam_role.${roleLogicalName}.name}`,
          policy: `jsonencode(${jsonDumpsIndent2(policyDict)})`
        }
      },
      __isImplicit: true
    };
    if (!domainKeys.includes(policyNodeKey)) {
      domainKeys.push(policyNodeKey);
      self.payload.domainNodeKeys = domainKeys;
    }
    self.generatedNodes.push(iamRolePolicyNode);
  });
}
__name(handleAwsIamRole, "handleAwsIamRole");
function handleAwsIamUser(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const userLogicalName = node.logicalName || params["name"] || "default_user";
  const userKey = node.key;
  const resourcesList = node["resources"] ?? [];
  const policiesDict = self.payload["policies"] ?? {};
  if (resourcesList.length === 0)
    return;
  const statements = [];
  for (const res of resourcesList) {
    const targetType = res["type"];
    const targetLogicalName = res["logicalName"];
    const permissionLevel = res["permission"];
    if (!targetType || !targetLogicalName)
      continue;
    if (!(targetType in policiesDict))
      continue;
    const actions = actionsForPermission(policiesDict[targetType], permissionLevel);
    if (!actions)
      continue;
    statements.push({ Effect: "Allow", Action: actions, Resource: [`\${${targetType}.${targetLogicalName}.arn}`] });
  }
  if (statements.length > 0) {
    const policyDict = { Version: "2012-10-17", Statement: statements };
    const policyNodeKey = `${userKey}_implicit_user_policy`;
    const policyLogicalName = `policy_${userLogicalName}`;
    const iamUserPolicyNode = {
      key: policyNodeKey,
      type: "aws_iam_user_policy",
      logicalName: policyLogicalName,
      group: node["group"],
      cloudResource: {
        uiState: {},
        params: {
          name: `${userLogicalName}-dynamic-policy`,
          user: `\${aws_iam_user.${userLogicalName}.name}`,
          policy: `jsonencode(${jsonDumpsIndent2(policyDict)})`
        }
      },
      __isImplicit: true
    };
    const domainKeys = self.payload.domainNodeKeys ?? [];
    if (!domainKeys.includes(policyNodeKey)) {
      domainKeys.push(policyNodeKey);
      self.payload.domainNodeKeys = domainKeys;
    }
    self.generatedNodes.push(iamUserPolicyNode);
  }
}
__name(handleAwsIamUser, "handleAwsIamUser");
function handleAwsIamInstanceProfile(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const embeddedRole = params["aws_iam_role"];
  if (!isPlainObject2(embeddedRole) || Object.keys(embeddedRole).length === 0)
    return;
  const profileLogicalName = node.logicalName || "Profile";
  const originalName = embeddedRole["originalLogicalName_"] || "";
  let roleLogicalName;
  if (originalName) {
    roleLogicalName = originalName;
  } else {
    const embeddedId = embeddedRole["id"] || "";
    roleLogicalName = embeddedId.includes(".") ? embeddedId.split(".").pop() : `${profileLogicalName}_role`;
  }
  const roleParams = {};
  for (const [k, v] of Object.entries(embeddedRole)) {
    if (k !== "id" && k !== "raw_json_" && k !== "originalLogicalName_")
      roleParams[k] = v;
  }
  const roleKey = `${node.key}_embedded_role`;
  const roleNode = {
    key: roleKey,
    type: "aws_iam_role",
    logicalName: roleLogicalName,
    group: node.group,
    cloudResource: { uiState: {}, params: roleParams },
    __isImplicit: true
  };
  if (!self.domainNodeKeys.includes(roleKey))
    self.domainNodeKeys.push(roleKey);
  self.generatedNodes.push(roleNode);
  if (self.nodeMap)
    self.nodeMap[roleKey] = roleNode;
  params["role"] = `\${aws_iam_role.${roleLogicalName}.name}`;
  delete params["aws_iam_role"];
}
__name(handleAwsIamInstanceProfile, "handleAwsIamInstanceProfile");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_iam_role() {
    return handleAwsIamRole(this);
  },
  handle_aws_iam_user() {
    return handleAwsIamUser(this);
  },
  handle_aws_iam_instance_profile() {
    return handleAwsIamInstanceProfile(this);
  }
});

// src/handlers/integration.ts
function handleAwsSnsTopic(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const isFifo = params["fifo_topic"] ?? false;
  if (isFifo) {
    const currentName = params["name"] ?? "";
    if (currentName && !String(currentName).endsWith(".fifo"))
      params["name"] = `${currentName}.fifo`;
  }
}
__name(handleAwsSnsTopic, "handleAwsSnsTopic");
function handleAwsSecretsmanagerSecretVersion(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const secretString = params["secret_string"];
  const secretBinary = params["secret_binary"];
  if (!secretString && !secretBinary)
    params["secret_string"] = " ";
}
__name(handleAwsSecretsmanagerSecretVersion, "handleAwsSecretsmanagerSecretVersion");
function handleAwsCurReportDefinition(self) {
  const node = self.node;
  node.cloudResource ??= {};
  node.cloudResource.params ??= {};
  const params = node.cloudResource.params;
  if (params["struct8_report_"] !== true)
    return;
  const bucketKeys = node.connections?.target?.["aws_s3_bucket"] ?? [];
  if (bucketKeys.length === 0)
    return;
  const bucketNode = self.nodeMap?.[bucketKeys[0]];
  if (bucketNode) {
    bucketNode.cloudResource ??= {};
    bucketNode.cloudResource.params ??= {};
    const bp = bucketNode.cloudResource.params;
    if (!("tags" in bp))
      bp["tags"] = {};
    bp["tags"]["Struct8Management"] = "Struct8CUR";
  }
}
__name(handleAwsCurReportDefinition, "handleAwsCurReportDefinition");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_sns_topic() {
    return handleAwsSnsTopic(this);
  },
  handle_aws_secretsmanager_secret_version() {
    return handleAwsSecretsmanagerSecretVersion(this);
  },
  handle_aws_cur_report_definition() {
    return handleAwsCurReportDefinition(this);
  }
});

// src/handlers/dns.ts
function addSafeDependsOn(self, currentNode, targetNode, targetRef) {
  if (!currentNode || !targetNode)
    return false;
  const stateCurrent = currentNode.terraformID || self.terraformKey;
  const stateTarget = targetNode.terraformID || self.terraformKey;
  if (stateCurrent && stateTarget && stateCurrent !== stateTarget)
    return false;
  currentNode.cloudResource ??= {};
  currentNode.cloudResource.params ??= {};
  const params = currentNode.cloudResource.params;
  if (!("depends_on" in params))
    params["depends_on"] = [];
  const dependsOnList = params["depends_on"];
  if (!dependsOnList.includes(targetRef)) {
    dependsOnList.push(targetRef);
    return true;
  }
  return false;
}
__name(addSafeDependsOn, "addSafeDependsOn");
function handlePreAwsRoute53Zone(self) {
  const node = self.node;
  const sourcesMap = node.connections?.source ?? {};
  const parents = [...sourcesMap["aws_route53_zone"] ?? [], ...sourcesMap["cldmn_subdomain"] ?? []];
  const params = node.cloudResource?.params ?? {};
  if (parents.length === 0) {
    const zoneName = params["name"] || params["subdomain"];
    node["pushCode"] = false;
    node["rootLogicalName"] = node.logicalName;
    if (zoneName) {
      const dsParams = { name: zoneName };
      if ("private_zone" in params)
        dsParams["private_zone"] = params["private_zone"];
      self.addGenericDataSource(self.nodes, "aws_route53_zone", node.logicalName ?? "Zone", dsParams);
    }
    return;
  }
  node["pushCode"] = false;
  const [fullDomainName, absoluteRootId] = self.resolveDnsHierarchyIterative(node, self.nodeMap ?? {});
  if (absoluteRootId)
    node["rootLogicalName"] = absoluteRootId;
  node.cloudResource ??= {};
  node.cloudResource.params ??= {};
  node.cloudResource.params["name"] = fullDomainName;
}
__name(handlePreAwsRoute53Zone, "handlePreAwsRoute53Zone");
function handleAwsCognitoUserPoolDomain(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const cognitoLogical = node.logicalName;
  const targetConfig = {
    logical_name: cognitoLogical,
    dns_name_ref: `aws_cognito_user_pool_domain.${cognitoLogical}.cloudfront_distribution`,
    zone_id_ref: `aws_cognito_user_pool_domain.${cognitoLogical}.cloudfront_distribution_zone_id`,
    evaluate_target_health: false
  };
  for (const { dnsNode, fullDomain, rootId } of self.yieldDnsContext(node, self.nodeMap ?? {})) {
    params["domain"] = fullDomain;
    self.createAliasRecord(dnsNode, node, rootId, fullDomain, targetConfig, "A");
    throw new Error("name 'f' is not defined");
  }
  const validationRef = "aws_acm_certificate_validation.Validation_Certificate1";
  let validationNode = null;
  for (const n of Object.values(self.nodeMap ?? {})) {
    if (n.type === "aws_acm_certificate_validation" && n.logicalName === "Validation_Certificate1") {
      validationNode = n;
      break;
    }
  }
  if (validationNode)
    addSafeDependsOn(self, node, validationNode, validationRef);
}
__name(handleAwsCognitoUserPoolDomain, "handleAwsCognitoUserPoolDomain");
function handleAwsAcmCertificate(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const acmLogicalName = node.logicalName;
  const params = node.cloudResource?.params ?? {};
  const sourceConnections = node.connections?.source ?? {};
  const r53Keys = sourceConnections["aws_route53_zone"] ?? [];
  const subdomainKeys = sourceConnections["cldmn_subdomain"] ?? [];
  const allZoneKeys = [...r53Keys, ...subdomainKeys];
  const domainConfigs = [];
  for (const key of allZoneKeys) {
    const sourceNode = nodeMap[key];
    if (sourceNode) {
      const [fullFqdn, rootId] = self.resolveDnsHierarchyIterative(sourceNode, nodeMap);
      if (fullFqdn) {
        const zoneLogicalName = rootId ? rootId : sourceNode.logicalName;
        const srcType = subdomainKeys.includes(key) ? "cldmn_subdomain" : "aws_route53_zone";
        const sourceParams = sourceNode.cloudResource?.params ?? {};
        const ttlValue = "ttl_" in sourceParams ? sourceParams["ttl_"] : 300;
        domainConfigs.push({ fqdn: fullFqdn, zone_logical_name: zoneLogicalName, zone_key: key, source_type: srcType, ttl: ttlValue });
      }
    }
  }
  if (domainConfigs.length === 0)
    return;
  params["domain_name"] = domainConfigs[0].fqdn;
  if (domainConfigs.length > 1)
    params["subject_alternative_names"] = domainConfigs.slice(1).map((d) => d.fqdn);
  const generatedRecordNodes = [];
  const generatedRecordNames = [];
  for (const dConf of domainConfigs) {
    const safeDomainName = dConf.fqdn.replaceAll(".", "_").replaceAll("-", "_");
    const recordLogicalName = `Route53_Record_${acmLogicalName}_${safeDomainName}`;
    const existingNode = self.generatedNodes.find((n) => n.logicalName === recordLogicalName) ?? null;
    if (existingNode) {
      if (!generatedRecordNames.includes(recordLogicalName)) {
        generatedRecordNames.push(recordLogicalName);
        generatedRecordNodes.push(existingNode);
      }
      continue;
    }
    const forEachHcl = `{
    for dvo in aws_acm_certificate.${acmLogicalName}.domain_validation_options : dvo.domain_name => dvo
    if dvo.domain_name == "${dConf.fqdn}"
  }`;
    const newRecordNode = self.addGenericNode(self.generatedNodes, "aws_route53_record", recordLogicalName, null, node);
    if (newRecordNode) {
      const recordParams = newRecordNode.cloudResource.params;
      recordParams["for_each"] = forEachHcl;
      recordParams["allow_overwrite"] = true;
      recordParams["name"] = "each.value.resource_record_name";
      recordParams["records"] = ["each.value.resource_record_value"];
      recordParams["type"] = "each.value.resource_record_type";
      recordParams["ttl"] = dConf.ttl;
      recordParams["zone_id"] = `aws_route53_zone.${dConf.zone_logical_name}.zone_id`;
      newRecordNode.connections = newRecordNode.connections ?? { source: {}, target: {} };
      newRecordNode.connections.source = { [dConf.source_type]: [dConf.zone_key] };
      generatedRecordNodes.push(newRecordNode);
      generatedRecordNames.push(recordLogicalName);
    }
  }
  const validationLogicalName = `Validation_${acmLogicalName}`;
  const newValidationNode = self.addGenericNode(self.generatedNodes, "aws_acm_certificate_validation", validationLogicalName, null, node);
  if (newValidationNode) {
    const valParams = newValidationNode.cloudResource.params;
    valParams["certificate_arn"] = `aws_acm_certificate.${acmLogicalName}.arn`;
    const timeoutsValidation = params["timeouts_validation_"];
    if (timeoutsValidation)
      valParams["timeouts"] = timeoutsValidation;
    if (generatedRecordNames.length === 1) {
      valParams["validation_record_fqdns"] = `[for record in aws_route53_record.${generatedRecordNames[0]} : record.fqdn]`;
    } else {
      let concatStr = "concat(\n";
      for (const rName of generatedRecordNames)
        concatStr += `    [for record in aws_route53_record.${rName} : record.fqdn],
`;
      concatStr += "  )";
      valParams["validation_record_fqdns"] = concatStr;
    }
    newValidationNode.connections = newValidationNode.connections ?? { source: {}, target: {} };
    newValidationNode.connections.target = {
      aws_acm_certificate: [node.key],
      aws_route53_record: generatedRecordNodes.map((n) => n.key)
    };
  }
}
__name(handleAwsAcmCertificate, "handleAwsAcmCertificate");
Object.assign(AwsProviderLogic.prototype, {
  handle_pre_aws_route53_zone() {
    return handlePreAwsRoute53Zone(this);
  },
  handle_aws_cognito_user_pool_domain() {
    return handleAwsCognitoUserPoolDomain(this);
  },
  handle_aws_acm_certificate() {
    return handleAwsAcmCertificate(this);
  }
});

// src/handlers/appsync.ts
function handleAwsAppsyncDatasource(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const name = params["name"];
  if (typeof name === "string")
    params["name"] = name.replaceAll("-", "_");
  if (params["type"] === "HTTP" && !params["http_config"])
    params["type"] = "NONE";
}
__name(handleAwsAppsyncDatasource, "handleAwsAppsyncDatasource");
var APPSYNC_AUTH_TYPE_MAP = {
  lambda_authorizer_config: "AWS_LAMBDA",
  user_pool_config: "AMAZON_COGNITO_USER_POOLS",
  openid_connect_config: "OPENID_CONNECT"
};
function handleAwsAppsyncGraphqlApi(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const connections = node.connections?.source ?? {};
  const appsyncKey = node.key;
  const targets = node.connections?.target ?? {};
  const hasCloudwatch = (targets["aws_cloudwatch_log_group"] ?? []).length > 0;
  const policyKeys = targets["cldmn_policy"] ?? [];
  if (hasCloudwatch && policyKeys.length > 0) {
    for (const pKey of policyKeys) {
      const policyNode = nodeMap[pKey];
      if (!policyNode)
        continue;
      const policyParams = policyNode.cloudResource?.params ?? {};
      const statements = policyParams["statement"] ?? [];
      for (const stmt of statements) {
        const resources = stmt["resources"];
        if (Array.isArray(resources)) {
          resources.forEach((resUri, idx) => {
            if (typeof resUri === "string" && resUri.includes("aws_cloudwatch_log_group")) {
              resources[idx] = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/appsync/apis/*:*";
            }
          });
        }
      }
    }
  }
  const hasVpcEndpoint = (connections["aws_vpc_endpoint_interface"] ?? []).length > 0;
  if (hasVpcEndpoint)
    params["visibility"] = "PRIVATE";
  else
    params["visibility"] = params["visibility"] ?? "GLOBAL";
  const hasApiKey = (connections["aws_appsync_api_key"] ?? []).length > 0;
  const additionalProviders = params["additional_authentication_provider"] ?? [];
  const primaryCandidates = [];
  const cleanedAdditionalProviders = [];
  if (Array.isArray(additionalProviders)) {
    for (const providerBlock of additionalProviders) {
      const providerKey = Object.keys(providerBlock)[0];
      const configData = providerBlock[providerKey];
      if (providerKey === "lambda_authorizer_config") {
        const lambdaName = configData["identity_validation_expression"];
        if (lambdaName)
          configData["authorizer_uri"] = `aws_lambda_function.${lambdaName}.invoke_arn`;
      } else if (providerKey === "user_pool_config") {
        const poolKeys = connections["aws_cognito_user_pool"] ?? [];
        const pools = poolKeys.map((k) => nodeMap[k]).filter((n) => !!n);
        if (pools.length > 0) {
          const poolNode = pools[0];
          configData["user_pool_id"] = `aws_cognito_user_pool.${poolNode.logicalName}.id`;
          const clientKeys = connections["aws_cognito_user_pool_client"] ?? [];
          const clients = clientKeys.map((k) => nodeMap[k]).filter((n) => !!n);
          const validClients = [];
          for (const client of clients) {
            const clientTargets = client.connections?.target?.["aws_cognito_user_pool"] ?? [];
            if (clientTargets.includes(poolNode.key))
              validClients.push(client);
            else
              self.collector.addError(["appsync_cognito_client_pool_mismatch", appsyncKey]);
          }
          if (validClients.length > 0) {
            configData["app_id_client_regex"] = validClients.map((c) => `\${aws_cognito_user_pool_client.${c.logicalName}.id}`).join("|");
          } else {
            configData["app_id_client_regex"] = "";
          }
        }
      }
      const isPrimary = "primary_" in configData ? configData["primary_"] : false;
      delete configData["primary_"];
      if (isPrimary) {
        primaryCandidates.push({ key: providerKey, config: configData });
      } else {
        providerBlock["authentication_type"] = APPSYNC_AUTH_TYPE_MAP[providerKey] ?? null;
        cleanedAdditionalProviders.push(providerBlock);
      }
    }
  }
  let candidates = primaryCandidates;
  if (candidates.length > 1) {
    self.collector.addError(["appsync_multiple_primary_providers", appsyncKey]);
    candidates = [candidates[0]];
  }
  if (candidates.length === 1) {
    const pKey = candidates[0].key;
    const pConfig = candidates[0].config;
    if ("default_action_" in pConfig) {
      pConfig["default_action"] = pConfig["default_action_"];
      delete pConfig["default_action_"];
    }
    params["authentication_type"] = APPSYNC_AUTH_TYPE_MAP[pKey] ?? null;
    params[pKey] = pConfig;
  } else {
    params["authentication_type"] = hasApiKey ? "API_KEY" : "AWS_IAM";
  }
  let iamAlreadyConfigured = params["authentication_type"] === "AWS_IAM";
  if (!iamAlreadyConfigured) {
    for (const provider of cleanedAdditionalProviders) {
      if (provider["authentication_type"] === "AWS_IAM") {
        iamAlreadyConfigured = true;
        break;
      }
    }
  }
  if (!iamAlreadyConfigured && cleanedAdditionalProviders.length < 5) {
    cleanedAdditionalProviders.push({ authentication_type: "AWS_IAM" });
  }
  if (cleanedAdditionalProviders.length > 0) {
    if (cleanedAdditionalProviders.length > 5)
      self.collector.addError(["appsync_additional_providers_limit_exceeded", appsyncKey]);
    params["additional_authentication_provider"] = cleanedAdditionalProviders;
  } else if ("additional_authentication_provider" in params) {
    delete params["additional_authentication_provider"];
  }
}
__name(handleAwsAppsyncGraphqlApi, "handleAwsAppsyncGraphqlApi");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_appsync_datasource() {
    return handleAwsAppsyncDatasource(this);
  },
  handle_aws_appsync_graphql_api() {
    return handleAwsAppsyncGraphqlApi(this);
  }
});

// src/handlers/lb.ts
function resolveEcsTargetType(self, containerKey) {
  const containerNode = self.nodeMap?.[containerKey];
  if (!containerNode)
    return "ip";
  let taskDefNode = null;
  const tdKey = containerNode.connections?.target?.["aws_ecs_task_definition"]?.[0];
  if (tdKey)
    taskDefNode = self.nodeMap?.[tdKey] ?? null;
  if (!taskDefNode)
    return "ip";
  const params = taskDefNode.cloudResource?.params ?? {};
  const networkMode = String(params["network_mode"] ?? "bridge").toLowerCase();
  return networkMode === "awsvpc" ? "ip" : "instance";
}
__name(resolveEcsTargetType, "resolveEcsTargetType");
function digSingleBlock(params, ...path) {
  let current = params;
  for (const key of path) {
    if (current === null || typeof current !== "object" || Array.isArray(current))
      return null;
    current = current[key];
    if (Array.isArray(current))
      current = current.length > 0 ? current[0] : null;
  }
  return current;
}
__name(digSingleBlock, "digSingleBlock");
function createTargetGroupBindingIfNeeded(self, tgNode) {
  const tgLogicalName = tgNode.logicalName;
  const tgTargets = tgNode.connections?.target ?? {};
  if (!tgTargets["kubernetes_gateway_api"] || tgTargets["kubernetes_gateway_api"].length === 0)
    return;
  const gatewayNode = self.nodeMap?.[tgTargets["kubernetes_gateway_api"][0]];
  if (!gatewayNode)
    return;
  const gwTargets = gatewayNode.connections?.target ?? {};
  if (!gwTargets["kubernetes_namespace"] || gwTargets["kubernetes_namespace"].length === 0)
    return;
  const namespaceNode = self.nodeMap?.[gwTargets["kubernetes_namespace"][0]];
  const nsLogicalName = namespaceNode?.logicalName;
  const gwSources = gatewayNode.connections?.source ?? {};
  let controllerNode = null;
  let srcType = "";
  for (const [sType, srcKeys] of Object.entries(gwSources)) {
    srcType = sType;
    if (sType.endsWith("_controller") && srcKeys.length > 0) {
      controllerNode = self.nodeMap?.[srcKeys[0]] ?? null;
      break;
    }
  }
  if (!controllerNode)
    return;
  const ctrlLogicalName = controllerNode.logicalName;
  const ctrlParams = controllerNode.cloudResource?.params ?? {};
  const ingressServiceName = digSingleBlock(ctrlParams, "spec", "dataPlaneOptions", "network", "services", "ingress", "name");
  let serviceName;
  if (ingressServiceName)
    serviceName = String(ingressServiceName).toLowerCase();
  else if (srcType === "kubernetes_app_kong_controller")
    serviceName = "kong-proxy-static";
  else
    serviceName = ctrlLogicalName.toLowerCase();
  const tgbLogicalName = `tgb_${tgLogicalName}`.toLowerCase();
  if (self.generatedNodes.some((n) => n.logicalName === tgbLogicalName))
    return;
  const tgbNode = self.addGenericNode(self.generatedNodes, "kubernetes_manifest", tgbLogicalName, gatewayNode, null, true);
  if (tgbNode) {
    tgbNode.cloudResource.params = {
      manifest: {
        apiVersion: "elbv2.k8s.aws/v1beta1",
        kind: "TargetGroupBinding",
        metadata: {
          name: `${tgLogicalName}-tgb`.toLowerCase(),
          namespace: `\${kubernetes_namespace.${nsLogicalName}.metadata[0].name}`
        },
        spec: {
          targetGroupARN: `\${aws_lb_target_group.${tgLogicalName}.arn}`,
          targetType: "ip",
          serviceRef: { name: serviceName, port: 80 }
        }
      }
    };
  }
}
__name(createTargetGroupBindingIfNeeded, "createTargetGroupBindingIfNeeded");
function createTargetGroupAttachment(self, tgNode, instanceNode) {
  const tgName = tgNode.logicalName;
  const instName = instanceNode.logicalName;
  const tgParams = tgNode.cloudResource?.params ?? {};
  const port = tgParams["port"] ?? 80;
  const attachLogicName = `attach_${instName}_to_${tgName}`;
  const newAttachNode = self.addGenericNode(self.generatedNodes, "aws_lb_target_group_attachment", attachLogicName, tgNode, instanceNode);
  if (newAttachNode) {
    const params = newAttachNode.cloudResource.params;
    params["target_group_arn"] = `aws_lb_target_group.${tgName}.arn`;
    params["target_id"] = `aws_instance.${instName}.id`;
    params["port"] = port;
    newAttachNode.connections = { target: { aws_lb_target_group: [tgNode.key] }, source: { aws_instance: [instanceNode.key] } };
  }
}
__name(createTargetGroupAttachment, "createTargetGroupAttachment");
function attachTgToAsg(tgNode, asgNode) {
  const tgName = tgNode.logicalName;
  const asgParams = asgNode.cloudResource?.params ?? {};
  if (!("target_group_arns" in asgParams))
    asgParams["target_group_arns"] = [];
  const tgReference = `aws_lb_target_group.${tgName}.arn`;
  if (!asgParams["target_group_arns"].includes(tgReference))
    asgParams["target_group_arns"].push(tgReference);
  asgParams["health_check_type"] = "ELB";
}
__name(attachTgToAsg, "attachTgToAsg");
function createLambdaTargetGroupAttachment(self, tgNode, lambdaNode) {
  const tgName = tgNode.logicalName;
  const lambdaName = lambdaNode.logicalName;
  const attachLogicName = `attach_${lambdaName}_to_${tgName}`;
  const newAttachNode = self.addGenericNode(self.generatedNodes, "aws_lb_target_group_attachment", attachLogicName, tgNode, lambdaNode);
  if (newAttachNode) {
    const params = newAttachNode.cloudResource.params;
    params["target_group_arn"] = `aws_lb_target_group.${tgName}.arn`;
    params["target_id"] = `aws_lambda_function.${lambdaName}.arn`;
    params["depends_on"] = [`aws_lambda_permission.perm_${tgName}_to_${lambdaName}`];
    newAttachNode.connections = { target: { aws_lb_target_group: [tgNode.key] }, source: { aws_lambda_function: [lambdaNode.key] } };
  }
}
__name(createLambdaTargetGroupAttachment, "createLambdaTargetGroupAttachment");
function handleAwsLbTargetGroup(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const connections = node.connections?.target ?? {};
  createTargetGroupBindingIfNeeded(self, node);
  const targetResType = Object.keys(connections)[0] ?? null;
  let computedTargetType = "ip";
  if (targetResType === "aws_ecs_container_") {
    const containerKeys = connections["aws_ecs_container_"] ?? [];
    if (containerKeys.length > 0)
      computedTargetType = resolveEcsTargetType(self, containerKeys[0]);
  } else {
    const typeMap = { aws_lambda_function: "lambda", aws_instance: "instance", aws_autoscaling_group: "instance", aws_lb: "alb" };
    computedTargetType = (targetResType && typeMap[targetResType]) ?? "ip";
  }
  params["target_type"] = computedTargetType;
  if (targetResType) {
    const targetKeys = connections[targetResType] ?? [];
    for (const key of targetKeys) {
      const targetNode = self.nodeMap?.[key];
      if (!targetNode)
        continue;
      if (targetResType === "aws_instance")
        createTargetGroupAttachment(self, node, targetNode);
      else if (targetResType === "aws_lambda_function")
        createLambdaTargetGroupAttachment(self, node, targetNode);
      else if (targetResType === "aws_autoscaling_group")
        attachTgToAsg(node, targetNode);
    }
  }
}
__name(handleAwsLbTargetGroup, "handleAwsLbTargetGroup");
function handleAwsLbXalb(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const allConnections = node.connections ?? {};
  const targetConnections = allConnections.target ?? {};
  const subnetIdsList = [];
  let eksNode = null;
  let gapiNode = null;
  const gapiNodes = findAllRecursiveConnections(node.key, ["kubernetes_gateway_api"], nodeMap, "target");
  if (gapiNodes.length > 0) {
    gapiNode = gapiNodes[0];
    const k8sCluster = findAncestorByType(gapiNode, "kubernetes_cluster_", nodeMap);
    if (k8sCluster) {
      const eksKeys = k8sCluster.connections?.source?.["aws_eks_cluster"] ?? [];
      if (eksKeys.length > 0)
        eksNode = nodeMap[eksKeys[0]] ?? null;
    }
    if (eksNode) {
      let vpcRef = "aws_vpc.main.id";
      const vpcKeys = eksNode.connections?.target?.["aws_vpc"] ?? [];
      if (vpcKeys.length > 0) {
        const vNode = nodeMap[vpcKeys[0]];
        if (vNode)
          vpcRef = `aws_vpc.${vNode.logicalName}.id`;
      }
      ensureEksLbController(self, eksNode, vpcRef, node);
    }
  }
  const hasListener = "aws_lb_listener" in targetConnections && (targetConnections["aws_lb_listener"] ?? []).length > 0;
  if (!hasListener) {
    const idx = self.nodes.indexOf(node);
    if (idx !== -1)
      self.nodes.splice(idx, 1);
  }
  if ("aws_subnet" in targetConnections) {
    for (const subnetKey of targetConnections["aws_subnet"] ?? []) {
      const subnetNode = nodeMap[subnetKey];
      if (subnetNode) {
        subnetIdsList.push(`aws_subnet.${subnetNode.logicalName}.id`);
        if (eksNode)
          applyEksSubnetTags(subnetNode, eksNode.logicalName);
      }
    }
  }
  if (subnetIdsList.length > 0)
    params["subnets"] = subnetIdsList;
  processLbDnsAliases(self, gapiNode, eksNode);
  return node;
}
__name(handleAwsLbXalb, "handleAwsLbXalb");
function ensureEksLbController(self, clusterNode, vpcIdRef, lbNode) {
  const clusterLogicalName = clusterNode.logicalName;
  const clusterKey = clusterNode.key;
  const lbLogicalName = String(lbNode.logicalName ?? "default_lb").toLowerCase();
  const controllerHelmLogicalName = `aws_lbc_${lbLogicalName}`;
  if (self.generatedNodes.some((n) => n.logicalName === controllerHelmLogicalName))
    return;
  const clusterRefName = `aws_eks_cluster.${clusterLogicalName}.name`;
  const oidcProviderLogicalName = `eks_oidc_${clusterLogicalName}`;
  const oidcArnRef = `aws_iam_openid_connect_provider.${oidcProviderLogicalName}.arn`;
  const oidcUrlRef = `aws_iam_openid_connect_provider.${oidcProviderLogicalName}.url`;
  self.registerRequiredProvider("http");
  const policyDataName = `lbc_iam_policy_${lbLogicalName}`;
  self.addGenericDataSource(self.nodes, "http", policyDataName, {
    url: "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
  });
  const policyResourceName = `AWSLoadBalancerControllerIAMPolicy_${lbLogicalName}`;
  const iamPolicyNode = self.addGenericNode(self.generatedNodes, "aws_iam_policy", policyResourceName, clusterNode, null);
  if (iamPolicyNode) {
    iamPolicyNode.cloudResource.params = {
      name: policyResourceName,
      path: "/",
      description: "AWS Load Balancer Controller IAM Policy",
      policy: `data.http.${policyDataName}.response_body`
    };
  }
  const trustDocLogicalName = `doc_trust_lbc_${lbLogicalName}`;
  const trustDocNode = self.addGenericNode(self.generatedNodes, "aws_iam_policy_document", trustDocLogicalName, clusterNode, null);
  if (trustDocNode) {
    trustDocNode["_temp_data_source_definition"] = {
      XTYPE: "aws_iam_policy_document",
      logicalName: trustDocLogicalName,
      statement: [
        {
          effect: "Allow",
          actions: ["sts:AssumeRoleWithWebIdentity"],
          principals: [{ type: "Federated", identifiers: [oidcArnRef] }],
          condition: [
            {
              test: "StringEquals",
              variable: `\${replace(${oidcUrlRef}, "https://", "")}:sub`,
              values: [`system:serviceaccount:kube-system:aws-lbc-${lbLogicalName}`]
            }
          ]
        }
      ]
    };
    trustDocNode.cloudResource.params = {};
  }
  const roleName = `role_lbc_${lbLogicalName}`;
  const roleNode = self.addGenericNode(self.generatedNodes, "aws_iam_role", roleName, clusterNode, null);
  if (roleNode) {
    roleNode.cloudResource.params = {
      name: roleName,
      assume_role_policy: `data.aws_iam_policy_document.${trustDocLogicalName}.json`
    };
  }
  const attachNode = self.addGenericNode(self.generatedNodes, "aws_iam_role_policy_attachment", `${roleName}_attach`, null, null);
  if (attachNode) {
    attachNode.cloudResource.params = {
      policy_arn: `aws_iam_policy.${policyResourceName}.arn`,
      role: `aws_iam_role.${roleName}.name`
    };
  }
  const helmNode = self.addGenericNode(self.generatedNodes, "helm_release", controllerHelmLogicalName, clusterNode, null);
  if (helmNode) {
    helmNode.cloudResource.params = {
      name: `aws-lbc-${lbLogicalName}`,
      repository: "https://aws.github.io/eks-charts",
      chart: "aws-load-balancer-controller",
      namespace: "kube-system",
      set: [
        { name: "clusterName", value: clusterRefName },
        { name: "serviceAccount.create", value: "true" },
        { name: "serviceAccount.name", value: `aws-lbc-${lbLogicalName}` },
        { name: "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn", value: `aws_iam_role.${roleName}.arn` },
        { name: "region", value: "data.aws_region.current.region" },
        { name: "vpcId", value: vpcIdRef }
      ]
    };
    helmNode.connections = helmNode.connections ?? { source: {}, target: {} };
    helmNode.connections.source = { aws_eks_cluster: [clusterKey] };
    const currentDependsOn = helmNode.cloudResource["depends_on"] ?? [];
    const dependenciesToAdd = [`aws_iam_role_policy_attachment.${roleName}_attach`];
    for (const [, n] of Object.entries(nodeMapEntries(self))) {
      if (n.type === "aws_eks_node_group") {
        const connections = n.connections ?? {};
        const srcClusters = connections.source?.["aws_eks_cluster"] ?? [];
        const tgtClusters = connections.target?.["aws_eks_cluster"] ?? [];
        if (srcClusters.includes(clusterKey) || tgtClusters.includes(clusterKey)) {
          dependenciesToAdd.push(`aws_eks_node_group.${n.logicalName}`);
        }
      }
    }
    for (const dep of dependenciesToAdd)
      if (!currentDependsOn.includes(dep))
        currentDependsOn.push(dep);
    helmNode.cloudResource.params["depends_on"] = currentDependsOn;
  }
}
__name(ensureEksLbController, "ensureEksLbController");
function nodeMapEntries(self) {
  return self.nodeMap ?? {};
}
__name(nodeMapEntries, "nodeMapEntries");
function processLbDnsAliases(self, gapiNode, eksNode) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  if (gapiNode) {
    const gapiLogicalName = String(gapiNode.logicalName ?? "");
    if (eksNode) {
      const allZones = findAllRecursiveConnections(node.key, ["aws_route53_zone"], nodeMap, "source");
      let zoneArns = allZones.map((z) => `aws_route53_zone.${z.logicalName}.arn`);
      if (zoneArns.length === 0)
        zoneArns = ["arn:aws:route53:::hostedzone/*"];
      createExternalDnsIam(self, eksNode, zoneArns);
    }
    if (gapiLogicalName)
      tagAcmForGatewayApi(self, node, nodeMap, gapiLogicalName);
  }
  const lbLogicalName = node.logicalName;
  const lbParams = node.cloudResource?.params ?? {};
  const ipAddressType = lbParams["ip_address_type"] ?? "ipv4";
  const targetConfig = {
    logical_name: lbLogicalName,
    dns_name_ref: `aws_lb.${lbLogicalName}.dns_name`,
    zone_id_ref: `aws_lb.${lbLogicalName}.zone_id`,
    evaluate_target_health: true
  };
  for (const { dnsNode, fullDomain, rootId } of self.yieldDnsContext(node, nodeMap)) {
    self.createAliasRecord(dnsNode, node, rootId, fullDomain, targetConfig, "A");
    if (ipAddressType !== "ipv4")
      self.createAliasRecord(dnsNode, node, rootId, fullDomain, targetConfig, "AAAA");
  }
}
__name(processLbDnsAliases, "processLbDnsAliases");
function tagAcmForGatewayApi(self, albNode, nodeMap, gapiLogicalName) {
  let domainNode = null;
  const connectionsSource = albNode.connections?.source ?? {};
  for (const [, srcKeys] of Object.entries(connectionsSource)) {
    for (const srcKey of srcKeys) {
      const srcNode = nodeMap[srcKey];
      if (srcNode && (srcNode.typeList ?? []).includes("Domain")) {
        domainNode = srcNode;
        break;
      }
    }
    if (domainNode)
      break;
  }
  if (!domainNode)
    return;
  const domainTargets = domainNode.connections?.target ?? {};
  const acmKeys = domainTargets["aws_acm_certificate"] ?? [];
  if (acmKeys.length === 0)
    return;
  const acmNode = nodeMap[acmKeys[0]];
  if (acmNode) {
    acmNode.cloudResource = acmNode.cloudResource ?? {};
    const params = acmNode.cloudResource.params = acmNode.cloudResource.params ?? {};
    if (typeof params["tags"] !== "object" || params["tags"] === null || Array.isArray(params["tags"]))
      params["tags"] = {};
    params["tags"][`kubernetes.io/cluster/${gapiLogicalName}`] = "shared";
  }
}
__name(tagAcmForGatewayApi, "tagAcmForGatewayApi");
function createExternalDnsIam(self, eksNode, domainZones) {
  const eksName = eksNode.logicalName ?? "cluster";
  const stateId = eksNode.terraformID;
  const currentStateName = (stateId != null ? self.stateNameMap[stateId] : void 0) ?? "UnknownState";
  const policyLogicalName = `policy_external_dns_${eksName}_st_${currentStateName}`;
  const roleLogicalName = `role_external_dns_${eksName}_st_${currentStateName}`;
  const policyDocName = `${policyLogicalName}_doc`;
  const policyStatements = [
    { sid: "AllowRoute53Changes", effect: "Allow", actions: ["route53:ChangeResourceRecordSets"], resources: domainZones },
    { sid: "AllowRoute53Listing", effect: "Allow", actions: ["route53:ListHostedZones", "route53:ListResourceRecordSets"], resources: ["*"] }
  ];
  const oidcUrl = `\${replace(aws_iam_openid_connect_provider.eks_oidc_${eksName}.url, "https://", "")}`;
  const trustDocName = `doc_trust_external_dns_${eksName}`;
  const oidcArn = `aws_iam_openid_connect_provider.eks_oidc_${eksName}.arn`;
  const trustStatements = [
    {
      effect: "Allow",
      principals: [{ type: "Federated", identifiers: [oidcArn] }],
      actions: ["sts:AssumeRoleWithWebIdentity"],
      condition: [{ test: "StringEquals", variable: `${oidcUrl}:sub`, values: ["system:serviceaccount:kube-system:external-dns"] }]
    }
  ];
  const newRoleNode = self.addGenericNode(self.generatedNodes, "aws_iam_role", roleLogicalName, eksNode);
  if (newRoleNode) {
    newRoleNode["__isGenerated"] = true;
    const rParams = newRoleNode.cloudResource.params;
    rParams["name"] = roleLogicalName;
    rParams["assume_role_policy"] = `data.aws_iam_policy_document.${trustDocName}.json`;
    newRoleNode["_temp_data_source_definition"] = {
      XTYPE: "aws_iam_policy_document",
      logicalName: trustDocName,
      statement: trustStatements
    };
  }
  const newPolicyNode = self.addGenericNode(self.generatedNodes, "aws_iam_policy", policyLogicalName, eksNode);
  if (newPolicyNode) {
    newPolicyNode["__isGenerated"] = true;
    const pParams = newPolicyNode.cloudResource.params;
    pParams["name"] = policyLogicalName;
    pParams["description"] = `External-DNS Route53 permissions for ${eksName}`;
    pParams["policy"] = `data.aws_iam_policy_document.${policyDocName}.json`;
    newPolicyNode["_temp_data_source_definition"] = {
      XTYPE: "aws_iam_policy_document",
      logicalName: policyDocName,
      statement: policyStatements
    };
  }
  const attachName = `attach_ext_dns_${eksName}_st_${currentStateName}`;
  const newAttach = self.addGenericNode(self.generatedNodes, "aws_iam_role_policy_attachment", attachName, newRoleNode);
  if (newAttach) {
    newAttach["__isGenerated"] = true;
    const aParams = newAttach.cloudResource.params;
    aParams["role"] = `aws_iam_role.${roleLogicalName}.name`;
    aParams["policy_arn"] = `aws_iam_policy.${policyLogicalName}.arn`;
  }
  return newRoleNode;
}
__name(createExternalDnsIam, "createExternalDnsIam");
function handleAwsAutoscalingPolicy(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  const logicalName = node.logicalName;
  const nodeId = node.key;
  if (params["policy_type"] !== "TargetTrackingScaling")
    return;
  const ttConfigs = params["target_tracking_configuration"] ?? [];
  for (const config2 of ttConfigs) {
    const rawSpec = config2["predefined_metric_specification"];
    let specDict;
    if (Array.isArray(rawSpec) && rawSpec.length > 0)
      specDict = rawSpec[0];
    else if (isPlainObject2(rawSpec))
      specDict = rawSpec;
    else
      specDict = {};
    const metricType = specDict["predefined_metric_type"];
    if (metricType !== "ALBRequestCountPerTarget")
      continue;
    let tgLogical;
    let albLogical;
    const dependenciesList = [];
    const policySources = node.connections?.source ?? {};
    const tgKeys = policySources["aws_lb_target_group"] ?? [];
    if (tgKeys.length === 0) {
      self.collector.addError(["asgpolicy_missing_tg_group", nodeId]);
      continue;
    }
    const tgNode = nodeMap[tgKeys[0]];
    if (!tgNode)
      continue;
    tgLogical = tgNode.logicalName;
    const tgSources = tgNode.connections?.source ?? {};
    const ruleKeys = tgSources["aws_lb_listener_rule"] ?? [];
    const listenerKeys = tgSources["aws_lb_listener"] ?? [];
    let listenerNode = null;
    if (ruleKeys.length > 0) {
      const ruleNode = nodeMap[ruleKeys[0]];
      if (ruleNode) {
        dependenciesList.push(`aws_lb_listener_rule.${ruleNode.logicalName}`);
        const ruleSources = ruleNode.connections?.source ?? {};
        const lKeysFromRule = ruleSources["aws_lb_listener"] ?? [];
        if (lKeysFromRule.length > 0)
          listenerNode = nodeMap[lKeysFromRule[0]] ?? null;
      }
    } else if (listenerKeys.length > 0) {
      listenerNode = nodeMap[listenerKeys[0]] ?? null;
    }
    if (listenerNode) {
      dependenciesList.push(`aws_lb_listener.${listenerNode.logicalName}`);
      const listenerSources = listenerNode.connections?.source ?? {};
      for (const lbType of ["aws_lb_Xalb", "aws_lb_Xglb", "aws_lb_Xlb"]) {
        const lbKeys = listenerSources[lbType] ?? [];
        if (lbKeys.length > 0) {
          const albNode = nodeMap[lbKeys[0]];
          if (albNode) {
            albLogical = albNode.logicalName;
            break;
          }
        }
      }
    }
    if (albLogical && tgLogical) {
      specDict["resource_label"] = `\${aws_lb.${albLogical}.arn_suffix}/\${aws_lb_target_group.${tgLogical}.arn_suffix}`;
      if (dependenciesList.length > 0) {
        let existingDeps = params["depends_on"] ?? [];
        if (!Array.isArray(existingDeps))
          existingDeps = [];
        params["depends_on"] = [.../* @__PURE__ */ new Set([...existingDeps, ...dependenciesList])];
      }
    }
  }
}
__name(handleAwsAutoscalingPolicy, "handleAwsAutoscalingPolicy");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_lb_target_group() {
    return handleAwsLbTargetGroup(this);
  },
  handle_aws_lb_Xalb() {
    return handleAwsLbXalb(this);
  },
  handle_aws_autoscaling_policy() {
    return handleAwsAutoscalingPolicy(this);
  }
});

// src/handlers/beanstalk.ts
function ensureSetting(settings, namespace, name, value) {
  for (const entry of settings) {
    if (entry && typeof entry === "object" && entry.namespace === namespace && entry.name === name)
      return;
  }
  settings.push({ namespace, name, value });
}
__name(ensureSetting, "ensureSetting");
function collectBeanstalkSubnetNodes(envNode, nodeMap) {
  const subnetKeys = [];
  const add = /* @__PURE__ */ __name((k) => {
    if (k && !subnetKeys.includes(k))
      subnetKeys.push(k);
  }, "add");
  const groupKey = envNode.group;
  const groupNode = groupKey ? nodeMap[groupKey] : null;
  if (groupNode && groupNode.type === "aws_subnet")
    add(groupKey);
  const conns = envNode.connections ?? {};
  for (const direction of ["target", "source"]) {
    const dirConns = conns[direction] ?? {};
    for (const sk of dirConns["aws_subnet"] ?? [])
      add(sk);
    for (const nik of dirConns["cldmn_network_interface"] ?? []) {
      const niNode = nodeMap[nik];
      const niGroup = niNode ? niNode.group : null;
      const gn = niGroup ? nodeMap[niGroup] : null;
      if (gn && gn.type === "aws_subnet")
        add(niGroup);
    }
  }
  const out = [];
  for (const k of subnetKeys) {
    const n = nodeMap[k];
    if (n && n.logicalName)
      out.push(n);
  }
  return out;
}
__name(collectBeanstalkSubnetNodes, "collectBeanstalkSubnetNodes");
function ensureBeanstalkNetworkSettings(self, envNode, params, nodeMap) {
  const subnetNodes = collectBeanstalkSubnetNodes(envNode, nodeMap);
  if (subnetNodes.length === 0)
    return;
  const settings = params["setting"] ??= [];
  const vpcNode = findAncestorByType(subnetNodes[0], "aws_vpc", nodeMap);
  if (vpcNode && vpcNode.logicalName) {
    ensureSetting(settings, "aws:ec2:vpc", "VPCId", `__RAW__aws_vpc.${vpcNode.logicalName}.id`);
  }
  const ec2Subnets = subnetNodes.filter((s) => !s["is_public"]);
  const elbSubnets = subnetNodes.filter((s) => s["is_public"]);
  if (ec2Subnets.length > 0) {
    const value = ec2Subnets.map((s) => `\${aws_subnet.${s.logicalName}.id}`).join(",");
    ensureSetting(settings, "aws:ec2:vpc", "Subnets", value);
  }
  if (elbSubnets.length > 0) {
    const value = elbSubnets.map((s) => `\${aws_subnet.${s.logicalName}.id}`).join(",");
    ensureSetting(settings, "aws:ec2:vpc", "ELBSubnets", value);
  }
}
__name(ensureBeanstalkNetworkSettings, "ensureBeanstalkNetworkSettings");
function wireBeanstalkSharedAlb(envNode, params, nodeMap) {
  const listenerKeys = envNode.connections?.target?.["aws_lb_listener"] ?? [];
  if (listenerKeys.length === 0)
    return;
  const listenerNode = nodeMap[listenerKeys[0]];
  if (!listenerNode)
    return;
  const albKeys = listenerNode.connections?.source?.["aws_lb_Xalb"] ?? [];
  if (albKeys.length === 0)
    return;
  const albNode = nodeMap[albKeys[0]];
  const albLogicalName = albNode ? albNode.logicalName : null;
  if (!albLogicalName)
    return;
  const listenerParams = listenerNode.cloudResource?.params ?? {};
  const port = listenerParams["port"] || 80;
  const protocol = listenerParams["protocol"] || "HTTP";
  const settings = params["setting"] ??= [];
  ensureSetting(settings, "aws:elasticbeanstalk:environment", "EnvironmentType", "LoadBalanced");
  ensureSetting(settings, "aws:elasticbeanstalk:environment", "LoadBalancerType", "application");
  ensureSetting(settings, "aws:elasticbeanstalk:environment", "LoadBalancerIsShared", "true");
  ensureSetting(settings, "aws:elbv2:loadbalancer", "SharedLoadBalancer", `__RAW__aws_lb.${albLogicalName}.arn`);
  ensureSetting(settings, `aws:elbv2:listener:${port}`, "rules", "default");
  ensureSetting(settings, "aws:elasticbeanstalk:environment:process:default", "Port", String(port));
  ensureSetting(settings, "aws:elasticbeanstalk:environment:process:default", "Protocol", protocol);
}
__name(wireBeanstalkSharedAlb, "wireBeanstalkSharedAlb");
function wireBeanstalkInstanceProfileRole(self, envNode, profileNode, nodeMap) {
  profileNode.cloudResource ??= {};
  const profileParams = profileNode.cloudResource.params ??= {};
  const existing = profileParams["role"];
  if (existing && String(existing).trim())
    return;
  const roleRef = self.findRoleReference(envNode, nodeMap);
  if (!roleRef)
    return;
  if (String(roleRef).includes("aws_iam_role."))
    profileParams["role"] = `__RAW__${roleRef}`;
  else
    profileParams["role"] = `__RAW__aws_iam_role.${roleRef}.name`;
}
__name(wireBeanstalkInstanceProfileRole, "wireBeanstalkInstanceProfileRole");
function ensureBeanstalkInstanceProfileSetting(params, profileLogicalName) {
  const settings = params["setting"] ??= [];
  ensureSetting(settings, "aws:autoscaling:launchconfiguration", "IamInstanceProfile", `__RAW__aws_iam_instance_profile.${profileLogicalName}.name`);
}
__name(ensureBeanstalkInstanceProfileSetting, "ensureBeanstalkInstanceProfileSetting");
function attachBeanstalkDefaultManagedPolicies(self, envNode, nodeMap) {
  const defaults = ["AWSElasticBeanstalkWebTier", "AWSElasticBeanstalkWorkerTier", "AWSElasticBeanstalkMulticontainerDocker"];
  for (const policyName of defaults)
    self.addManagedPolicy(envNode, policyName, nodeMap);
}
__name(attachBeanstalkDefaultManagedPolicies, "attachBeanstalkDefaultManagedPolicies");
function handlePreAwsElasticBeanstalkEnvironment(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const params = node.cloudResource?.params ?? {};
  ensureBeanstalkNetworkSettings(self, node, params, nodeMap);
  wireBeanstalkSharedAlb(node, params, nodeMap);
  const profileKeys = node.connections?.source?.["aws_iam_instance_profile"] ?? [];
  if (profileKeys.length === 0)
    return;
  const profileNode = nodeMap[profileKeys[0]];
  if (!profileNode)
    return;
  const profileLogicalName = profileNode.logicalName;
  if (!profileLogicalName)
    return;
  ensureBeanstalkInstanceProfileSetting(params, profileLogicalName);
  wireBeanstalkInstanceProfileRole(self, node, profileNode, nodeMap);
  attachBeanstalkDefaultManagedPolicies(self, node, nodeMap);
}
__name(handlePreAwsElasticBeanstalkEnvironment, "handlePreAwsElasticBeanstalkEnvironment");
Object.assign(AwsProviderLogic.prototype, {
  handle_pre_aws_elastic_beanstalk_environment() {
    return handlePreAwsElasticBeanstalkEnvironment(this);
  }
});

// src/handlers/cloudfront.ts
function pyTruthy2(v) {
  if (v == null)
    return false;
  if (typeof v === "boolean")
    return v;
  if (typeof v === "number")
    return v !== 0;
  if (typeof v === "string")
    return v.length > 0;
  if (Array.isArray(v))
    return v.length > 0;
  if (typeof v === "object")
    return Object.keys(v).length > 0;
  return Boolean(v);
}
__name(pyTruthy2, "pyTruthy");
function pyOr2(a, b) {
  return pyTruthy2(a) ? a : b;
}
__name(pyOr2, "pyOr");
function pyInt(x, dflt = 0) {
  if (typeof x === "number")
    return Math.trunc(x);
  if (typeof x === "boolean")
    return x ? 1 : 0;
  if (typeof x === "string" && /^[+-]?\d+$/.test(x.trim()))
    return parseInt(x.trim(), 10);
  return dflt;
}
__name(pyInt, "pyInt");
function getS3Config(node, originId) {
  return { domain_name: `aws_s3_bucket.${node.logicalName}.bucket_regional_domain_name`, origin_id: originId };
}
__name(getS3Config, "getS3Config");
function getLbConfig(node, originId) {
  return { domain_name: `aws_lb.${node.logicalName}.dns_name`, origin_id: originId };
}
__name(getLbConfig, "getLbConfig");
function getApigwConfig(self, node, originId) {
  const nodeMap = self.nodeMap ?? {};
  const sourceApis = node.connections?.source?.["aws_api_gateway_rest_api"] ?? [];
  const restApiId = sourceApis[0];
  const restApiNode = nodeMap[restApiId];
  const restApiLogicalName = restApiNode?.logicalName;
  const domainName = `\${aws_api_gateway_rest_api.${restApiLogicalName}.id}.execute-api.\${data.aws_region.current.region}.amazonaws.com`;
  return { domain_name: domainName, origin_id: originId };
}
__name(getApigwConfig, "getApigwConfig");
function resolveConnectedOrigins(self, containerNode, defaultOriginId) {
  const nodeMap = self.nodeMap ?? {};
  const resolvedItems = [];
  const sourceConnections = containerNode.connections?.source ?? {};
  const handlerTypes = /* @__PURE__ */ new Set(["aws_s3_bucket", "aws_lb_Xalb", "aws_api_gateway_stage"]);
  for (const [resourceType, resourceIds] of Object.entries(sourceConnections)) {
    if (!handlerTypes.has(resourceType))
      continue;
    for (const resId of resourceIds) {
      const connectedNode = nodeMap[resId];
      if (!connectedNode)
        continue;
      let config2;
      if (resourceType === "aws_s3_bucket")
        config2 = getS3Config(connectedNode, defaultOriginId);
      else if (resourceType === "aws_lb_Xalb")
        config2 = getLbConfig(connectedNode, defaultOriginId);
      else
        config2 = getApigwConfig(self, connectedNode, defaultOriginId);
      const currentNodeOrigins = containerNode.cloudResource?.params?.["origin"];
      if (Array.isArray(currentNodeOrigins) && currentNodeOrigins.length > 0) {
        const userDefinedParams = currentNodeOrigins[0];
        for (const [key, value] of Object.entries(userDefinedParams)) {
          if (key !== "domain_name")
            config2[key] = value;
        }
      }
      resolvedItems.push([config2, connectedNode]);
    }
  }
  return resolvedItems;
}
__name(resolveConnectedOrigins, "resolveConnectedOrigins");
function ensureOacOrOaiExists(self, originConfig, sourceNode, parentNode) {
  const custConfig = originConfig["custom_origin_config"];
  if (custConfig) {
    if (Array.isArray(custConfig) && custConfig.length > 0 || isPlainObject2(custConfig) && Object.keys(custConfig).length > 0) {
      return originConfig;
    }
  }
  let isS3 = false;
  if (sourceNode) {
    if (sourceNode.type === "aws_s3_bucket")
      isS3 = true;
  }
  if (!isS3) {
    const originId = originConfig["origin_id"] ?? "";
    const domainName = String(originConfig["domain_name"] ?? "");
    const isS3Id = String(originId).includes("S3-");
    const isS3Config = "s3_origin_config" in originConfig;
    const isS3Domain = domainName.includes("s3.") || domainName.includes(".s3") || domainName.includes("aws_s3_bucket");
    if (isS3Id || isS3Config || isS3Domain)
      isS3 = true;
  }
  if (!isS3)
    return originConfig;
  let baseName;
  if (sourceNode) {
    baseName = String(sourceNode.logicalName ?? "unknown").toLowerCase();
  } else {
    const safeId = originConfig["origin_id"] ?? "s3-external";
    baseName = String(safeId).replaceAll("_", "-").replaceAll(".", "-").toLowerCase();
  }
  baseName = baseName.replaceAll("oac_", "");
  const logicalName = `oac_${baseName}`;
  const exists = self.nodes.some((n) => n.logicalName === logicalName);
  if (!exists) {
    const createdNode = self.addGenericNode(self.nodes, "aws_cloudfront_origin_access_control", logicalName, sourceNode, parentNode);
    if (createdNode) {
      createdNode.cloudResource.params = {
        name: `oac-${baseName}`,
        description: `OAC for ${baseName}`,
        origin_access_control_origin_type: "s3",
        signing_behavior: "always",
        signing_protocol: "sigv4"
      };
    }
  }
  originConfig["origin_access_control_id"] = `aws_cloudfront_origin_access_control.${logicalName}.id`;
  originConfig["s3_origin_config"] = [];
  if (sourceNode && parentNode) {
    const bucketLogicalName = sourceNode.logicalName;
    const distLogicalName = parentNode.logicalName;
    const bucketTerraId = sourceNode.terraformID;
    const distTerraId = parentNode.terraformID;
    const bucketArn = `\${aws_s3_bucket.${bucketLogicalName}.arn}`;
    let conditionBlock;
    if (bucketTerraId !== distTerraId) {
      conditionBlock = { StringEquals: { "AWS:SourceAccount": "data.aws_caller_identity.current.account_id" } };
    } else {
      const distArn = `arn:aws:cloudfront::\${data.aws_caller_identity.current.account_id}:distribution/\${aws_cloudfront_distribution.${distLogicalName}.id}`;
      conditionBlock = { StringEquals: { "AWS:SourceArn": distArn } };
    }
    const statement = [
      {
        Sid: "AllowCloudFrontServicePrincipalReadOnly",
        Effect: "Allow",
        Principal: [{ type: "Service", identifiers: ["cloudfront.amazonaws.com"] }],
        Action: "s3:GetObject",
        Resource: `${bucketArn}/*`,
        Condition: conditionBlock
      }
    ];
    self.createDynamicPolicy(sourceNode, `S3Access_CF_${distLogicalName}`, statement);
  }
  return originConfig;
}
__name(ensureOacOrOaiExists, "ensureOacOrOaiExists");
function processBehaviorPolicies(self, behaviorConfig, sourceParams) {
  const policyMap = {
    managed_origin_request_policy_: ["aws_cloudfront_origin_request_policy", "origin_request_policy_id"],
    managed_policy_: ["aws_cloudfront_cache_policy", "cache_policy_id"],
    managed_response_headers_policy_: ["aws_cloudfront_response_headers_policy", "response_headers_policy_id"]
  };
  for (const [inputKey, [resourceType, outputKey]] of Object.entries(policyMap)) {
    const value = pyOr2(behaviorConfig[inputKey], sourceParams[inputKey]);
    if (inputKey in behaviorConfig)
      delete behaviorConfig[inputKey];
    if (!pyTruthy2(value))
      continue;
    const valueStr = String(value);
    if (valueStr.startsWith("Managed-")) {
      const logicalNameSuffix = valueStr.replaceAll("Managed-", "").replaceAll("-", "_").replaceAll(" ", "_").toLowerCase();
      const dsLogicalName = `policy_${logicalNameSuffix}`;
      if (!self.nodes.some((n) => n.logicalName === dsLogicalName)) {
        self.addGenericDataSource(self.nodes, resourceType, dsLogicalName, { name: valueStr });
      }
      behaviorConfig[outputKey] = `data.${resourceType}.${dsLogicalName}.id`;
    } else {
      behaviorConfig[outputKey] = value;
    }
  }
}
__name(processBehaviorPolicies, "processBehaviorPolicies");
function validateBehaviorFunctionSlots(self, behavior, nodeKey) {
  if (!behavior)
    return;
  const usedEventTypes = /* @__PURE__ */ new Set();
  let lambdaAssocs = behavior["lambda_function_association"] ?? [];
  let cfFunctions = behavior["function_association"] ?? [];
  if (isPlainObject2(lambdaAssocs))
    lambdaAssocs = [lambdaAssocs];
  if (isPlainObject2(cfFunctions))
    cfFunctions = [cfFunctions];
  const allAssocs = [...pyOr2(lambdaAssocs, []), ...pyOr2(cfFunctions, [])];
  for (const assoc of allAssocs) {
    const eventType = assoc["event_type"];
    if (!eventType)
      continue;
    if (usedEventTypes.has(eventType)) {
      self.collector.addError(["cloudfront_behavior_duplicate_event_slot", nodeKey]);
      break;
    }
    usedEventTypes.add(eventType);
  }
}
__name(validateBehaviorFunctionSlots, "validateBehaviorFunctionSlots");
function configureAcmCertificate(self, dnsNode, viewerCertConfig) {
  const dnsTargets = dnsNode.connections?.target ?? {};
  const acmKeys = dnsTargets["aws_acm_certificate"] ?? [];
  if (acmKeys.length > 0) {
    const acmNode = self.nodeMap?.[acmKeys[0]];
    if (acmNode) {
      viewerCertConfig["cloudfront_default_certificate"] = false;
      viewerCertConfig["acm_certificate_arn"] = `aws_acm_certificate.${acmNode.logicalName}.arn`;
      viewerCertConfig["ssl_support_method"] = "sni-only";
      viewerCertConfig["minimum_protocol_version"] = "TLSv1.2_2021";
      return true;
    }
  }
  return false;
}
__name(configureAcmCertificate, "configureAcmCertificate");
function processCloudfrontCertificatesAndAliases(self, params) {
  const node = self.node;
  const aliases = [];
  let foundCertificate = false;
  if (!("viewer_certificate" in params) || !Array.isArray(params["viewer_certificate"])) {
    params["viewer_certificate"] = [{}];
  }
  const viewerCertConfig = params["viewer_certificate"][0];
  const cfLogicalName = node.logicalName;
  const targetConfig = {
    logical_name: cfLogicalName,
    dns_name_ref: `aws_cloudfront_distribution.${cfLogicalName}.domain_name`,
    zone_id_ref: `aws_cloudfront_distribution.${cfLogicalName}.hosted_zone_id`,
    evaluate_target_health: false
  };
  for (const { dnsNode, fullDomain, rootId } of self.yieldDnsContext(node, self.nodeMap ?? {})) {
    aliases.push(fullDomain);
    self.createAliasRecord(dnsNode, node, rootId, fullDomain, targetConfig, "A");
    self.createAliasRecord(dnsNode, node, rootId, fullDomain, targetConfig, "AAAA");
    if (!foundCertificate)
      foundCertificate = configureAcmCertificate(self, dnsNode, viewerCertConfig);
  }
  if (!foundCertificate && !viewerCertConfig["acm_certificate_arn"]) {
    viewerCertConfig["cloudfront_default_certificate"] = true;
  }
  if (aliases.length > 0)
    params["aliases"] = aliases;
}
__name(processCloudfrontCertificatesAndAliases, "processCloudfrontCertificatesAndAliases");
function processCloudfrontOriginsAndBehaviors(self, params, rawOrigins) {
  const nodeMap = self.nodeMap ?? {};
  const cfNode = self.node;
  const cfLogicalName = cfNode.logicalName ?? "cf_dist";
  const cfNodeKey = cfNode.key;
  rawOrigins.forEach((manualOrgRaw, i) => {
    let manualOrg = manualOrgRaw;
    if (typeof manualOrg === "string")
      manualOrg = { domain_name: manualOrg };
    if (!isPlainObject2(manualOrg))
      return;
    if (!("origin_id" in manualOrg))
      manualOrg["origin_id"] = `manual_origin_${i}_${cfLogicalName}`;
    manualOrg = ensureOacOrOaiExists(self, manualOrg, null, cfNode);
    params["origin"].push(manualOrg);
  });
  const sourceConnections = cfNode.connections?.source ?? {};
  const originKeys = sourceConnections["aws_cloudfront_origin_"] ?? [];
  const satelliteBehaviors = [];
  let defaultOriginsCount = 0;
  const seenPriorities = /* @__PURE__ */ new Set();
  let duplicatePriorityFlagged = false;
  for (const originKey of originKeys) {
    const originNode = nodeMap[originKey];
    if (!originNode)
      continue;
    const originLogicalName = originNode.logicalName ?? `Origin_${String(originKey).slice(0, 5)}`;
    const originParams = originNode.cloudResource?.params ?? {};
    const originId = `origin_${originLogicalName}`;
    const resolvedConnections = resolveConnectedOrigins(self, originNode, originId);
    let realSourceNode = null;
    let newOrigin = null;
    const rawOrigin = originParams["origin"];
    const customOrigins = isPlainObject2(rawOrigin) ? [rawOrigin] : Array.isArray(rawOrigin) ? rawOrigin : [];
    if (resolvedConnections.length > 0) {
      [newOrigin, realSourceNode] = resolvedConnections[0];
      newOrigin["origin_id"] = originId;
    } else if (customOrigins.length > 0 && isPlainObject2(customOrigins[0])) {
      newOrigin = customOrigins[0];
      newOrigin["origin_id"] = originId;
    }
    if (!newOrigin)
      continue;
    newOrigin = ensureOacOrOaiExists(self, newOrigin, realSourceNode, cfNode);
    params["origin"].push(newOrigin);
    const isDefaultRaw = originParams["is_default_"] ?? false;
    const isDefault = typeof isDefaultRaw === "string" ? ["true", "1", "yes"].includes(isDefaultRaw.toLowerCase()) : pyTruthy2(isDefaultRaw);
    if (isDefault) {
      defaultOriginsCount += 1;
      if ("default_cache_behavior" in params && Array.isArray(params["default_cache_behavior"])) {
        for (const defaultBehavior of params["default_cache_behavior"]) {
          defaultBehavior["target_origin_id"] = originId;
          for (const field of ["allowed_methods", "cached_methods"]) {
            if (typeof defaultBehavior[field] === "string")
              defaultBehavior[field] = defaultBehavior[field].split(",").map((m) => m.trim());
          }
          processBehaviorPolicies(self, defaultBehavior, defaultBehavior);
          validateBehaviorFunctionSlots(self, defaultBehavior, cfNode.key);
        }
      }
    }
    const originTargets = originNode.connections?.target ?? {};
    const behaviorKeys = originTargets["aws_cloudfront_behavior_"] ?? [];
    for (const behaviorKey of behaviorKeys) {
      const behaviorNode = nodeMap[behaviorKey];
      if (!behaviorNode)
        continue;
      const behaviorLogicalName = behaviorNode.logicalName ?? `Behavior_${String(behaviorKey).slice(0, 5)}`;
      const behaviorParams = behaviorNode.cloudResource?.params ?? {};
      const rawBehavior = behaviorParams["ordered_cache_behavior"];
      const customBehaviors = isPlainObject2(rawBehavior) ? [rawBehavior] : Array.isArray(rawBehavior) ? rawBehavior : [];
      if (customBehaviors.length > 0 && isPlainObject2(customBehaviors[0])) {
        const newBehavior = customBehaviors[0];
        newBehavior["target_origin_id"] = originId;
        for (const field of ["allowed_methods", "cached_methods"]) {
          if (typeof newBehavior[field] === "string")
            newBehavior[field] = newBehavior[field].split(",").map((m) => m.trim());
        }
        if (!pyTruthy2(newBehavior["path_pattern"])) {
          const sanitizedName = sanitizeToKebabCase(behaviorLogicalName);
          newBehavior["path_pattern"] = `/${sanitizedName}/*`;
        }
        processBehaviorPolicies(self, newBehavior, behaviorParams);
        validateBehaviorFunctionSlots(self, newBehavior, behaviorNode.key);
        const priority = pyInt(behaviorParams["order_priority_"] ?? 0, 0);
        if (seenPriorities.has(priority) && !duplicatePriorityFlagged) {
          self.collector.addError(["cf_duplicate_behavior_priority", cfNodeKey]);
          duplicatePriorityFlagged = true;
        }
        seenPriorities.add(priority);
        satelliteBehaviors.push({ priority, behavior: newBehavior, nodeRef: behaviorNode });
      }
    }
    const oidx = self.nodes.indexOf(originNode);
    if (oidx !== -1)
      self.nodes.splice(oidx, 1);
  }
  satelliteBehaviors.sort((a, b) => a.priority - b.priority);
  for (const item of satelliteBehaviors) {
    params["ordered_cache_behavior"].push(item.behavior);
    const bidx = self.nodes.indexOf(item.nodeRef);
    if (bidx !== -1)
      self.nodes.splice(bidx, 1);
  }
  if (defaultOriginsCount === 0 && "default_cache_behavior" in params && Array.isArray(params["default_cache_behavior"]) && pyTruthy2(params["origin"])) {
    const fallbackId = params["origin"][0]["origin_id"];
    params["default_cache_behavior"][0]["target_origin_id"] = fallbackId;
  }
}
__name(processCloudfrontOriginsAndBehaviors, "processCloudfrontOriginsAndBehaviors");
function configureCloudfrontS3Logging(self, cfNode, params) {
  const cfTargets = cfNode.connections?.target ?? {};
  const s3TargetKeys = cfTargets["aws_s3_bucket"] ?? [];
  if (s3TargetKeys.length === 0)
    return;
  const logBucketKey = s3TargetKeys[0];
  const logBucketNode = self.nodes.find((n) => n.key === logBucketKey) ?? null;
  if (!logBucketNode)
    return;
  const bucketLogicalName = logBucketNode.logicalName;
  const bucketSources = logBucketNode.connections?.source ?? {};
  const ownershipKeys = bucketSources["aws_s3_bucket_ownership_controls"] ?? [];
  const ownershipRule = [{ object_ownership: "BucketOwnerPreferred" }];
  let ownershipResourceRef = null;
  if (ownershipKeys.length > 0) {
    const ownershipNode = self.nodes.find((n) => n.key === ownershipKeys[0]) ?? null;
    if (ownershipNode) {
      ownershipNode.cloudResource.params["rule"] = ownershipRule;
      const existingLogicalName = ownershipNode.logicalName;
      if (existingLogicalName)
        ownershipResourceRef = `aws_s3_bucket_ownership_controls.${existingLogicalName}`;
    }
  } else {
    const ownershipLogicalName = `${bucketLogicalName}_ownership_controls`;
    const newOwnershipNode = self.addGenericNode(self.nodes, "aws_s3_bucket_ownership_controls", ownershipLogicalName, cfNode, logBucketNode);
    if (newOwnershipNode) {
      newOwnershipNode.cloudResource.params = { bucket: `aws_s3_bucket.${bucketLogicalName}.id`, rule: ownershipRule };
      ownershipResourceRef = `aws_s3_bucket_ownership_controls.${ownershipLogicalName}`;
    }
  }
  const aclKeys = bucketSources["aws_s3_bucket_acl"] ?? [];
  const targetAcl = "log-delivery-write";
  if (aclKeys.length > 0) {
    const aclNode = self.nodes.find((n) => n.key === aclKeys[0]) ?? null;
    if (aclNode) {
      const aclParams = aclNode.cloudResource.params;
      aclParams["acl"] = targetAcl;
      if (ownershipResourceRef) {
        const currentDepends = aclParams["depends_on"] ?? [];
        if (!currentDepends.includes(ownershipResourceRef)) {
          currentDepends.push(ownershipResourceRef);
          aclParams["depends_on"] = currentDepends;
        }
      }
    }
  } else {
    const aclLogicalName = `${bucketLogicalName}_acl`;
    const newAclNode = self.addGenericNode(self.nodes, "aws_s3_bucket_acl", aclLogicalName, cfNode, logBucketNode);
    if (newAclNode) {
      newAclNode.cloudResource.params = { bucket: `aws_s3_bucket.${bucketLogicalName}.id`, acl: targetAcl };
      if (ownershipResourceRef)
        newAclNode.cloudResource.params["depends_on"] = [ownershipResourceRef];
    }
  }
}
__name(configureCloudfrontS3Logging, "configureCloudfrontS3Logging");
function handleAwsCloudfrontDistribution(self) {
  const node = self.node;
  const params = node.cloudResource?.params ?? {};
  const originInput = params["origin"];
  let rawOrigins;
  if (isPlainObject2(originInput))
    rawOrigins = [originInput];
  else if (Array.isArray(originInput))
    rawOrigins = [...originInput];
  else
    rawOrigins = [];
  params["origin"] = [];
  params["ordered_cache_behavior"] = [];
  processCloudfrontOriginsAndBehaviors(self, params, rawOrigins);
  const uniqueOriginsMap = {};
  for (const org of params["origin"] ?? []) {
    const oid = org["origin_id"];
    if (oid)
      uniqueOriginsMap[oid] = org;
  }
  params["origin"] = Object.values(uniqueOriginsMap);
  processCloudfrontCertificatesAndAliases(self, params);
  configureCloudfrontS3Logging(self, node, params);
}
__name(handleAwsCloudfrontDistribution, "handleAwsCloudfrontDistribution");
Object.assign(AwsProviderLogic.prototype, {
  handle_aws_cloudfront_distribution() {
    return handleAwsCloudfrontDistribution(this);
  }
});

// src/handlers/k8s.ts
function pyGet(obj, key, dflt) {
  const v = obj[key];
  return v === void 0 ? dflt : v;
}
__name(pyGet, "pyGet");
function pyStr(v) {
  if (v === null || v === void 0)
    return "None";
  if (v === true)
    return "True";
  if (v === false)
    return "False";
  return String(v);
}
__name(pyStr, "pyStr");
function pyOr3(...vals) {
  for (const v of vals.slice(0, -1)) {
    if (v !== null && v !== void 0 && v !== false && v !== 0 && v !== "" && !(Array.isArray(v) && v.length === 0))
      return v;
  }
  return vals[vals.length - 1];
}
__name(pyOr3, "pyOr");
function parseRepoId(url) {
  if (!url || typeof url !== "string")
    return null;
  let cleaned = url.trim().replace(/\/+$/, "");
  if (cleaned.endsWith(".git"))
    cleaned = cleaned.slice(0, -4);
  cleaned = cleaned.replaceAll(":", "/");
  const parts = cleaned.split("/").filter((p) => p);
  if (parts.length < 2)
    return null;
  const owner = parts[parts.length - 2];
  const repoSlug = parts[parts.length - 1];
  return `${owner}-${repoSlug}`.toLowerCase().replaceAll("_", "-");
}
__name(parseRepoId, "parseRepoId");
function buildGitopsRepositories(self, argocdNode, namespaceName, namespaceLogical) {
  const nodeMap = self.nodeMap ?? {};
  const configsRepositories = {};
  const projectKeys = argocdNode.connections?.source?.["kubernetes_argocd_project_"] ?? [];
  for (const projKey of projectKeys) {
    const projNode = nodeMap[projKey];
    if (!projNode)
      continue;
    const projParams = projNode.cloudResource?.params ?? {};
    const rawRepos = pyOr3(pyGet(projParams, "source_repos", ""), "");
    const repoUrls = pyStr(rawRepos).split(",").map((u) => u.trim()).filter((u) => u);
    if (repoUrls.length === 0)
      continue;
    const repoCredentials = {};
    const secretKeys = projNode.connections?.source?.["kubernetes_secret_v1"] ?? [];
    if (secretKeys.length > 0) {
      const secretNode = nodeMap[secretKeys[0]];
      if (secretNode) {
        const originalData = pyGet(secretNode.cloudResource?.params ?? {}, "data", {});
        const secretNsRef = namespaceLogical ? `__RAW__kubernetes_namespace.${namespaceLogical}.metadata[0].name` : namespaceName;
        const secretParams = {
          type: "Opaque",
          metadata: [{ name: `secret-${secretNode.logicalName}`, namespace: secretNsRef }],
          data: originalData
        };
        if (namespaceLogical)
          secretParams["depends_on"] = [`kubernetes_namespace.${namespaceLogical}`];
        secretNode.cloudResource = secretNode.cloudResource ?? {};
        secretNode.cloudResource.params = secretParams;
        repoCredentials["username"] = "gitops-token";
        repoCredentials["password"] = `__RAW__kubernetes_secret_v1.${secretNode.logicalName}.data.password`;
      }
    }
    for (const repoUrl of repoUrls) {
      if (repoUrl.includes("*"))
        continue;
      const repoId = parseRepoId(repoUrl);
      if (!repoId)
        continue;
      const repoData = { name: repoId, url: repoUrl, type: "git" };
      Object.assign(repoData, repoCredentials);
      configsRepositories[repoId] = repoData;
    }
  }
  return configsRepositories;
}
__name(buildGitopsRepositories, "buildGitopsRepositories");
function injectPrometheusAnnotations(node, helmCustomValues, nodeMap) {
  const nodeSources = node.connections?.source ?? {};
  const hasPrometheus = "kubernetes_app_prometheus_stack" in nodeSources;
  const hasServiceMonitor = "kubernetes_service_monitor_app_" in nodeSources;
  if (!hasPrometheus && !hasServiceMonitor)
    return;
  let interval = "30s";
  let scrapeTimeout = "10s";
  if (hasServiceMonitor) {
    const smKey = nodeSources["kubernetes_service_monitor_app_"][0];
    const smNode = nodeMap[smKey];
    const smParams = smNode?.cloudResource?.params ?? {};
    interval = smParams["interval"] ?? interval;
    scrapeTimeout = smParams["scrape_timeout"] ?? scrapeTimeout;
  }
  const componentsMapping = {
    server: "argocd-server",
    controller: "argocd-application-controller",
    repoServer: "argocd-repo-server",
    applicationSet: "argocd-applicationset-controller"
  };
  for (const [helmKey, jobRegexName] of Object.entries(componentsMapping)) {
    if (!(helmKey in helmCustomValues))
      helmCustomValues[helmKey] = {};
    if (!("metrics" in helmCustomValues[helmKey]))
      helmCustomValues[helmKey]["metrics"] = {};
    Object.assign(helmCustomValues[helmKey]["metrics"], {
      enabled: true,
      serviceMonitor: {
        enabled: true,
        interval,
        scrapeTimeout,
        relabelings: [{ sourceLabels: ["job"], regex: `.*(${jobRegexName}).*`, targetLabel: "job", replacement: "$1" }]
      }
    });
  }
}
__name(injectPrometheusAnnotations, "injectPrometheusAnnotations");
function handleKubernetesAppArgocd(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const appParams = node.cloudResource?.params ?? {};
  const logicalName = node.logicalName;
  const namespaceKeys = node.connections?.target?.["kubernetes_namespace"] ?? [];
  let namespaceName = appParams["namespace"];
  let namespaceLogical = null;
  let tfNamespaceRef = namespaceName;
  if (namespaceKeys.length > 0) {
    const namespaceNode = nodeMap[namespaceKeys[0]];
    if (namespaceNode) {
      namespaceLogical = namespaceNode.logicalName;
      namespaceName = namespaceLogical;
      tfNamespaceRef = `__RAW__kubernetes_namespace.${namespaceLogical}.metadata[0].name`;
    }
  }
  const configsRepositories = buildGitopsRepositories(self, node, namespaceName, namespaceLogical);
  const helmCustomValues = { configs: { repositories: configsRepositories } };
  const isInsecure = appParams["server_insecure"] ?? false;
  if (isInsecure)
    helmCustomValues["server"] = { extraArgs: ["--insecure"] };
  injectPrometheusAnnotations(node, helmCustomValues, nodeMap);
  const helmNodeArgocd = self.addGenericNode(self.generatedNodes, "helm_release", `helm_${logicalName}`, node, null);
  if (helmNodeArgocd) {
    helmNodeArgocd.cloudResource.params = {
      name: logicalName.toLowerCase(),
      repository: "https://argoproj.github.io/argo-helm",
      chart: "argo-cd",
      namespace: tfNamespaceRef,
      create_namespace: false,
      version: appParams["chart_version"] ?? "5.46.0",
      timeout: appParams["timeout"] ?? 600,
      wait: appParams["wait"] ?? true,
      atomic: appParams["atomic"] ?? true,
      values: [{ __yamlencode__: helmCustomValues }]
    };
    const dependsOnList = [];
    if (namespaceLogical)
      dependsOnList.push(`kubernetes_namespace.${namespaceLogical}`);
    const nodeSources = node.connections?.source ?? {};
    if ("kubernetes_app_prometheus_stack" in nodeSources)
      dependsOnList.push("helm_release.app_kube_prometheus_stack");
    if (dependsOnList.length > 0)
      helmNodeArgocd.cloudResource.params["depends_on"] = dependsOnList;
  }
  buildArgocdBootstrap(self, node, tfNamespaceRef, namespaceName, logicalName);
  return node;
}
__name(handleKubernetesAppArgocd, "handleKubernetesAppArgocd");
function k8sGitopsEnvPath(self, helmNode) {
  const nodeMap = self.nodeMap ?? {};
  const clusterNode = findAncestorByType(helmNode, "kubernetes_cluster_", nodeMap);
  if (!clusterNode)
    return null;
  let accountId = k8sClusterAccountId(self, clusterNode);
  if (!accountId) {
    const k3sSources = clusterNode.connections?.source?.["k3s_cluster_"] ?? [];
    for (const key of k3sSources) {
      const k3sNode = nodeMap[key];
      if (k3sNode && k3sNode.logicalName) {
        accountId = k3sNode.logicalName;
        break;
      }
    }
  }
  if (!accountId)
    return null;
  const tfName = helmNode.logicalName;
  if (!tfName)
    return null;
  return `${accountId}/${tfName}/templates`;
}
__name(k8sGitopsEnvPath, "k8sGitopsEnvPath");
function k8sClusterAccountId(self, clusterNode) {
  const nodeMap = self.nodeMap ?? {};
  if (!clusterNode)
    return null;
  const sources = clusterNode.connections?.source ?? {};
  for (const managedType of ["aws_eks_cluster"]) {
    for (const key of sources[managedType] ?? []) {
      const managedNode = nodeMap[key];
      if (!managedNode)
        continue;
      const cloudNode = findAncestorByType(managedNode, "aws_cloud_", nodeMap);
      if (!cloudNode)
        continue;
      const accountId = (cloudNode.cloudResource?.params ?? {})["account_id"];
      if (accountId)
        return String(accountId);
    }
  }
  return null;
}
__name(k8sClusterAccountId, "k8sClusterAccountId");
function buildArgocdBootstrap(self, argocdNode, tfNamespaceRef, namespaceName, argocdLogicalName) {
  const nodeMap = self.nodeMap ?? {};
  const nodes = self.payload?.nodes ?? [];
  const helmEnvs = nodes.filter((n) => n.type === "kubernetes_helm_chart");
  if (helmEnvs.length === 0)
    return;
  const applicationsDict = {};
  for (const env2 of helmEnvs) {
    const envName = env2.logicalName;
    const envParams = env2.cloudResource?.params ?? {};
    const repoUrl = envParams["repo"];
    const project = envParams["project"];
    if (!repoUrl || repoUrl === "None" || !project || project === "None") {
      self.collector.addWarning([
        `Ambiente Helm '${envName}': sem Project/Repo selecionado -- Application do ArgoCD nao gerada (o push gravaria no Git sem ninguem sincronizando).`,
        env2.key
      ]);
      continue;
    }
    const envPath = k8sGitopsEnvPath(self, env2);
    if (!envPath) {
      self.collector.addWarning([
        `Ambiente Helm '${envName}': nao foi possivel descobrir a conta AWS do cluster -- Application do ArgoCD nao gerada. A conta e' derivada da topologia: ligue o no' do cluster EKS ao kubernetes_cluster_ (a conta vem de onde o EKS esta).`,
        env2.key
      ]);
      continue;
    }
    let destNs = null;
    const groupNode = env2.group ? nodeMap[env2.group] : void 0;
    if (groupNode && groupNode.type === "kubernetes_namespace")
      destNs = groupNode.logicalName ?? null;
    if (!destNs) {
      self.collector.addWarning([
        `Ambiente Helm '${envName}': nao esta dentro de um kubernetes_namespace -- Application do ArgoCD nao gerada.`,
        env2.key
      ]);
      continue;
    }
    const appName = String(envName).toLowerCase();
    applicationsDict[appName] = {
      name: appName,
      namespace: namespaceName,
      // onde a Application vive (namespace do ArgoCD)
      finalizers: ["resources-finalizer.argocd.argoproj.io"],
      // kebab-case: precisa bater com o metadata.name do AppProject (RFC 1123,
      // minúsculo), que passa pelo MESMO sanitizador em buildArgocdProjects. O
      // usuário digita o nome com a caixa que quiser (ex: "Proj2"); os dois
      // lados convergem pro mesmo valor sanitizado.
      project: sanitizeToKebabCase(project),
      source: { repoURL: repoUrl, targetRevision: "HEAD", path: envPath },
      destination: {
        server: "https://kubernetes.default.svc",
        namespace: destNs
        // onde os recursos do ambiente nascem
      },
      syncPolicy: { automated: { prune: true, selfHeal: true } }
    };
  }
  const projectsDict = buildArgocdProjects(self, argocdNode, namespaceName);
  if (Object.keys(applicationsDict).length === 0)
    return;
  const helmValues = { applications: applicationsDict };
  if (Object.keys(projectsDict).length > 0)
    helmValues["projects"] = projectsDict;
  const helmNodeApps = self.addGenericNode(self.generatedNodes, "helm_release", "argocd_applications", argocdNode, null);
  if (helmNodeApps) {
    helmNodeApps.cloudResource.params = {
      name: "argocd-apps",
      repository: "https://argoproj.github.io/argo-helm",
      chart: "argocd-apps",
      version: "1.4.1",
      namespace: tfNamespaceRef,
      values: [{ __yamlencode__: helmValues }],
      depends_on: [`helm_release.helm_${argocdLogicalName}`]
    };
    self.collector.addInfo([
      `ArgoCD '${argocdLogicalName}': ${Object.keys(applicationsDict).length} Application(s) e ${Object.keys(projectsDict).length} AppProject(s) de bootstrap geradas.`,
      argocdNode.key
    ]);
  }
}
__name(buildArgocdBootstrap, "buildArgocdBootstrap");
function buildArgocdProjects(self, argocdNode, namespaceName) {
  const nodeMap = self.nodeMap ?? {};
  const projectsDict = {};
  const projKeys = argocdNode.connections?.source?.["kubernetes_argocd_project_"] ?? [];
  for (const pkey of projKeys) {
    const pnode = nodeMap[pkey];
    if (!pnode)
      continue;
    const pp = pnode.cloudResource?.params ?? {};
    const projNameRaw = pyOr3(pp["project_name"], pnode.logicalName, "").trim();
    if (!projNameRaw)
      continue;
    const projName = sanitizeToKebabCase(projNameRaw);
    if (!projName)
      continue;
    const sourceRepos = pyStr(pyGet(pp, "source_repos", "")).split(",").map((r) => r.trim()).filter((r) => r);
    let destServers = pyStr(pyGet(pp, "destinations", "")).split(",").map((d) => d.trim()).filter((d) => d && d !== "*");
    if (destServers.length === 0)
      destServers = ["https://kubernetes.default.svc"];
    const destinations = destServers.map((s) => ({ server: s, namespace: "*" }));
    projectsDict[projName] = {
      name: projName,
      namespace: namespaceName,
      description: pyGet(pp, "description", ""),
      sourceRepos: sourceRepos.length > 0 ? sourceRepos : ["*"],
      destinations,
      // Escopo cluster-wide: os ambientes criam CRDs de vários grupos (Gateway
      // API, Kong, Prometheus) e recursos cluster-scoped (GatewayClass).
      // Restringir aqui só reintroduziria o mesmo tipo de bloqueio ("resource
      // not permitted in project").
      clusterResourceWhitelist: [{ group: "*", kind: "*" }]
    };
  }
  return projectsDict;
}
__name(buildArgocdProjects, "buildArgocdProjects");
function handleKubernetesNamespace(self) {
  const node = self.node;
  const nodeMap = self.nodeMap ?? {};
  const logicalName = node.logicalName;
  node.cloudResource = node.cloudResource ?? {};
  node.cloudResource.params = { metadata: [{ name: logicalName }] };
  const isBundleManaged = self.nodes.some((n) => n.group === node.key && String(n.type ?? "").startsWith("kubernetes_app_"));
  const clusterNode = findAncestorByType(node, "kubernetes_cluster_", nodeMap);
  if (clusterNode && !isBundleManaged) {
    const zt = clusterNode.cloudResource?.params?.["zeroTrust"];
    const zeroTrust = zt === void 0 ? true : Boolean(zt);
    if (zeroTrust) {
      const netpolLogicalName = `netpol-default-deny-${logicalName}`.toLowerCase();
      if (!self.generatedNodes.some((n) => n.logicalName === netpolLogicalName)) {
        const netpolNode = self.addGenericNode(self.generatedNodes, "kubernetes_manifest", netpolLogicalName, node, null, true);
        if (netpolNode) {
          netpolNode.cloudResource.params = {
            manifest: {
              apiVersion: "networking.k8s.io/v1",
              kind: "NetworkPolicy",
              metadata: {
                name: `default-deny-ingress-${logicalName}`.toLowerCase(),
                namespace: `\${kubernetes_namespace.${logicalName}.metadata[0].name}`
              },
              spec: { podSelector: {}, policyTypes: ["Ingress"] }
            }
          };
        }
      }
    }
  }
}
__name(handleKubernetesNamespace, "handleKubernetesNamespace");
Object.assign(AwsProviderLogic.prototype, {
  handle_kubernetes_app_argocd() {
    return handleKubernetesAppArgocd(this);
  },
  handle_kubernetes_namespace() {
    return handleKubernetesNamespace(this);
  }
});

// src/pipeline.ts
function syncNamespacesAndDomainKeys(payload) {
  const rootTerraformKey = payload.terraformKey;
  const nodes = payload.nodes ?? [];
  let isK8sIntegrated = false;
  if (!rootTerraformKey || nodes.length === 0)
    return [payload, isK8sIntegrated];
  const rootNode = nodes.find((n) => n.key === rootTerraformKey);
  if (!rootNode)
    return [payload, isK8sIntegrated];
  let parentId = rootNode["group"];
  const data = rootNode["data"];
  if (!parentId && data && typeof data === "object")
    parentId = data["group"];
  if (!parentId)
    return [payload, isK8sIntegrated];
  const parentNode = nodes.find((n) => n.key === parentId);
  if (!parentNode)
    return [payload, isK8sIntegrated];
  if (parentNode.type !== "kubernetes_cluster_")
    return [payload, isK8sIntegrated];
  isK8sIntegrated = true;
  const domainKeysSet = new Set(payload.domainNodeKeys ?? []);
  for (const node of nodes) {
    if (node.type === "kubernetes_namespace") {
      node.terraformID = rootTerraformKey;
      if (node.key)
        domainKeysSet.add(node.key);
    }
  }
  payload.domainNodeKeys = [...domainKeysSet];
  return [payload, isK8sIntegrated];
}
__name(syncNamespacesAndDomainKeys, "syncNamespacesAndDomainKeys");
function generateTerraform(inputPayload, defaultsData = {}) {
  const [payload, isK8sIntegrated] = syncNamespacesAndDomainKeys(inputPayload);
  if (!Array.isArray(payload.domainNodeKeys))
    payload.domainNodeKeys = [];
  const domainNodeKeys = payload.domainNodeKeys;
  const dynamicIgnoredTypes = /* @__PURE__ */ new Set(["cldmn_terraform"]);
  for (const node of payload.nodes ?? []) {
    if (node.type && node.type.endsWith("_"))
      dynamicIgnoredTypes.add(node.type);
  }
  const coreGen = new HCLGenerator({
    ignoredTypes: dynamicIgnoredTypes,
    datasourceStrategies: DATASOURCE_STRATEGIES,
    datasourceHandlers: DATASOURCE_HANDLERS,
    regionResolver: findAccountAndRegionName
  });
  const awsLogic = new AwsProviderLogic(coreGen);
  const nodes = payload.nodes ?? [];
  const nodeMap = {};
  for (const node of nodes)
    if (node.key != null)
      nodeMap[node.key] = node;
  let targetRegion = null;
  let targetAccountId = null;
  for (const node of nodes) {
    const params = node.cloudResource?.params ?? {};
    if (node.type === "aws_cloud_")
      targetAccountId = params["account_id"] ?? null;
    else if (node.type === "aws_region_")
      targetRegion = params["region_name"] ?? null;
    if (targetRegion && targetAccountId)
      break;
  }
  const tfConfig = payload.terraformConfig ?? {};
  let backendConfig = {};
  if (tfConfig["bucketName"]) {
    backendConfig = {
      bucket: tfConfig["bucketName"],
      key: tfConfig["stateKey"],
      dynamodb_table: tfConfig["lockTable"],
      region: tfConfig["region"],
      role_arn: tfConfig["backendRoleArn"]
    };
  }
  const terraformKey = payload.terraformKey ?? null;
  awsLogic.setContext(payload, domainNodeKeys, terraformKey, nodeMap);
  awsLogic.preProcessNodes();
  awsLogic.processNodes();
  awsLogic.preprocessIamPolicies();
  awsLogic.preprocessSecurityGroups();
  awsLogic.preprocessK8sAwsGlue();
  awsLogic.enrichAwsTagsAndRemoveNodes();
  const validator = new AwsValidator(awsLogic.collector);
  validator.validateNodes(payload.nodes ?? [], nodeMap, domainNodeKeys);
  const hclHeader = awsLogic.generateHeader(targetRegion, targetAccountId, backendConfig);
  const allNodes = payload.nodes ?? [];
  const externalNodesMap = {};
  for (const node of allNodes) {
    if (!domainNodeKeys.includes(node.key) && node.logicalName)
      externalNodesMap[node.logicalName] = node;
  }
  coreGen.externalNodesLookup = externalNodesMap;
  const hclResources = coreGen.generateHclText(payload, defaultsData, domainNodeKeys, nodeMap, isK8sIntegrated);
  let fullCode = `${hclHeader}

${hclResources}`;
  fullCode = coreGen.applyStringReplacements(fullCode);
  const [errors, warnings, infos] = awsLogic.collector.getAll(domainNodeKeys);
  return { terraform: fullCode, errors, warnings, infos };
}
__name(generateTerraform, "generateTerraform");

// src/lambdaHandler.ts
var SUCCESS_HEADERS = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "OPTIONS,POST,GET",
  "Access-Control-Allow-Headers": "Content-Type"
};
function isObject(v) {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
__name(isObject, "isObject");
function lambdaHandler(event, _context) {
  let bodyData;
  try {
    if (isObject(event) && "body" in event) {
      const rawBody = event.body;
      bodyData = rawBody ? JSON.parse(rawBody) : {};
    } else {
      bodyData = event;
    }
  } catch (e) {
    return {
      statusCode: 400,
      headers: { "Access-Control-Allow-Origin": "*" },
      body: JSON.stringify(["", [], [], [`Invalid JSON input: ${e?.message ?? e}`], []])
    };
  }
  const dataInput = bodyData && "dados" in bodyData ? bodyData["dados"] : bodyData;
  try {
    let payload;
    let defaultsData;
    if (dataInput && "diagram_payload" in dataInput && isObject(dataInput["diagram_payload"])) {
      payload = dataInput["diagram_payload"];
      defaultsData = dataInput["defaults_data"] ?? {};
    } else {
      payload = dataInput;
      defaultsData = {};
    }
    const result = generateTerraform(payload, defaultsData);
    const responseData = [result.terraform, [], [], result.errors, result.warnings, result.infos];
    return {
      statusCode: 200,
      headers: SUCCESS_HEADERS,
      body: JSON.stringify(responseData)
    };
  } catch (e) {
    const errorMessage = `Erro fatal ao gerar Terraform: ${e?.message ?? e}`;
    return {
      statusCode: 500,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type"
      },
      body: JSON.stringify(["", [], [], [errorMessage], []])
    };
  }
}
__name(lambdaHandler, "lambdaHandler");

// src/worker.ts
var HclAwsGenerator = class extends WorkerEntrypoint {
  /**
   * Gera o Terraform de um payload de diagrama.
   *
   * RPC em vez de HTTP de propósito: o gateway chama
   * `env.HCLAWS.generate(payload)` e recebe o objeto direto, sem serializar uma
   * requisição HTTP no meio de dois Workers que rodam na MESMA thread. O
   * contrato de 6 posições do `response_data` continua idêntico ao da Lambda --
   * é o que permite comparar o HCL byte a byte na prova de equivalência.
   *
   * @param payload O corpo que o frontend manda hoje pra Lambda (`{dados: ...}`
   *                ou o payload direto). Repassado sem interpretação: quem
   *                decide o formato é o `lambdaHandler`, o mesmo dos dois lados.
   */
  generate(payload) {
    return lambdaHandler(payload);
  }
  /**
   * Só pra diagnóstico do binding. NÃO é rota pública -- o Worker não tem uma.
   * Serve pra confirmar, de dentro do gateway, que o binding está resolvendo
   * para o Worker/estágio certo.
   */
  version() {
    return { worker: "hclaws", ok: true };
  }
  /**
   * Sem `fetch`: um Worker privado não recebe requisição HTTP. Deixar um fetch
   * aqui só criaria a ilusão de que ele pode ser chamado direto -- e mascararia
   * o erro de configuração no dia em que `workers_dev` voltasse a `true`.
   */
};
__name(HclAwsGenerator, "HclAwsGenerator");
export {
  HclAwsGenerator as default
};
//# sourceMappingURL=worker.js.map
