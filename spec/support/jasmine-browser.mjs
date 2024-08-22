export default {
  srcDir: "assets",
  srcFiles: [
    "message-bus.js",
    "message-bus-ajax.js"
  ],
  specDir: "spec/assets",
  specFiles: [
    "message-bus.spec.js"
  ],
  helpers: [
    "SpecHelper.js"
  ],
  env: {
    stopSpecOnExpectationFailure: false,
    stopOnSpecFailure: false,
    random: true
  },

  // For security, listen only to localhost. You can also specify a different
  // hostname or IP address, or remove the property or set it to "*" to listen
  // to all network interfaces.
  listenAddress: "localhost",

  // The hostname that the browser will use to connect to the server.
  hostname: "localhost",

  browser: {
    name: "headlessChrome"
  }
};
