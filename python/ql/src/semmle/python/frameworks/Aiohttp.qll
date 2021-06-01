/**
 * Provides classes modeling security-relevant aspects of the `aiohttp` PyPI package.
 * See https://docs.aiohttp.org/en/stable/index.html
 */

private import python
private import semmle.python.dataflow.new.DataFlow
private import semmle.python.dataflow.new.RemoteFlowSources
private import semmle.python.dataflow.new.TaintTracking
private import semmle.python.Concepts
private import semmle.python.ApiGraphs
private import semmle.python.frameworks.internal.PoorMansFunctionResolution
private import semmle.python.frameworks.Multidict
private import semmle.python.frameworks.Yarl

/**
 * INTERNAL: Do not use.
 *
 * Provides models for the web server part (`aiohttp.web`) of the `aiohttp` PyPI package.
 * See https://docs.aiohttp.org/en/stable/web.html
 */
module AiohttpWebModel {
  /**
   * Provides models for the `aiohttp.web.View` class and subclasses.
   *
   * See https://docs.aiohttp.org/en/stable/web_reference.html#view.
   */
  module View {
    /** Gets a reference to the `flask.views.View` class or any subclass. */
    API::Node subclassRef() {
      result = API::moduleImport("aiohttp").getMember("web").getMember("View").getASubclass*()
    }
  }

  // -- route modeling --
  /** Gets a reference to a `aiohttp.web.Application` instance. */
  API::Node applicationInstance() {
    // Not sure whether you're allowed to add routes _after_ starting the app, for
    // example in the middle of handling a http request... but I'm guessing that for 99%
    // for all code, not modeling that `request.app` is a reference to an application
    // should be good enough for the route-setup part of the modeling :+1:
    result = API::moduleImport("aiohttp").getMember("web").getMember("Application").getReturn()
  }

  /** Gets a reference to a `aiohttp.web.UrlDispatcher` instance. */
  API::Node urlDispathcerInstance() {
    result = API::moduleImport("aiohttp").getMember("web").getMember("UrlDispatcher").getReturn()
    or
    result = applicationInstance().getMember("router")
  }

  /** A route setup in `aiohttp.web` */
  abstract class AiohttpRouteSetup extends HTTP::Server::RouteSetup::Range {
    override Parameter getARoutedParameter() { none() }

    override string getFramework() { result = "aiohttp.web" }
  }

  /** An aiohttp route setup that uses coroutines (async function) as request handler. */
  abstract class AiohttpCoroutineRouteSetup extends AiohttpRouteSetup {
    /** Gets the argument specifying the request handler (which is a coroutine/async function) */
    abstract DataFlow::Node getRequestHandlerArg();

    override Function getARequestHandler() {
      this.getRequestHandlerArg() = poorMansFunctionTracker(result)
    }
  }

  /**
   * Gets a reference to a class, that has been backtracked from the view-class handler
   * argument `origin` (to a route-setup for view-classes).
   */
  private DataFlow::LocalSourceNode viewClassBackTracker(
    DataFlow::TypeBackTracker t, DataFlow::Node origin
  ) {
    t.start() and
    origin = any(AiohttpViewRouteSetup rs).getViewClassArg() and
    result = origin.getALocalSource()
    or
    exists(DataFlow::TypeBackTracker t2 |
      result = viewClassBackTracker(t2, origin).backtrack(t2, t)
    )
  }

  /**
   * Gets a reference to a class, that has been backtracked from the view-class handler
   * argument `origin` (to a route-setup for view-classes).
   */
  DataFlow::LocalSourceNode viewClassBackTracker(DataFlow::Node origin) {
    result = viewClassBackTracker(DataFlow::TypeBackTracker::end(), origin)
  }

  Class getBackTrackedViewClass(DataFlow::Node origin) {
    result.getParent() = viewClassBackTracker(origin).asExpr()
  }

  /** An aiohttp route setup that uses view-classes as request handlers. */
  abstract class AiohttpViewRouteSetup extends AiohttpRouteSetup {
    /** Gets the argument specifying the view-class handler. */
    abstract DataFlow::Node getViewClassArg();

    /** Gets the view-class that is referenced in the view-class handler argument. */
    Class getViewClass() { result = getBackTrackedViewClass(this.getViewClassArg()) }

    override Function getARequestHandler() {
      exists(AiohttpViewClass cls |
        cls = this.getViewClass() and
        result = cls.getARequestHandler()
      )
    }
  }

  /**
   * A route-setup from `add_route` or any of `add_get`, `add_post`, etc. on an
   *    `aiohttp.web.UrlDispatcher`.
   */
  class AiohttpUrlDispatcherAddRouteCall extends AiohttpCoroutineRouteSetup, DataFlow::CallCfgNode {
    /** At what index route arguments starts, so we can handle "route" version together with get/post/... */
    int routeArgsStart;

    AiohttpUrlDispatcherAddRouteCall() {
      this = urlDispathcerInstance().getMember("add_" + HTTP::httpVerbLower()).getACall() and
      routeArgsStart = 0
      or
      this = urlDispathcerInstance().getMember("add_route").getACall() and
      routeArgsStart = 1
    }

    override DataFlow::Node getUrlPatternArg() {
      result in [this.getArg(routeArgsStart + 0), this.getArgByName("path")]
    }

    override DataFlow::Node getRequestHandlerArg() {
      result in [this.getArg(routeArgsStart + 1), this.getArgByName("handler")]
    }
  }

  /**
   * A route-setup from using `route` or any of `get`, `post`, etc. functions from `aiohttp.web`.
   *
   * Note that technically, this does not set up a route in itself (since it needs to be added to an application first).
   * However, modeling this way makes it easier, and we don't expect it to lead to many problems.
   */
  class AiohttpWebRouteCall extends AiohttpCoroutineRouteSetup, DataFlow::CallCfgNode {
    /** At what index route arguments starts, so we can handle "route" version together with get/post/... */
    int routeArgsStart;

    AiohttpWebRouteCall() {
      exists(string funcName |
        funcName = HTTP::httpVerbLower() and
        routeArgsStart = 0
        or
        funcName = "route" and
        routeArgsStart = 1
      |
        this = API::moduleImport("aiohttp").getMember("web").getMember(funcName).getACall()
      )
    }

    override DataFlow::Node getUrlPatternArg() {
      result in [this.getArg(routeArgsStart + 0), this.getArgByName("path")]
    }

    override DataFlow::Node getRequestHandlerArg() {
      result in [this.getArg(routeArgsStart + 1), this.getArgByName("handler")]
    }
  }

  /** A route-setup from using a `route` or any of `get`, `post`, etc. decorators from a `aiohttp.web.RouteTableDef`. */
  class AiohttpRouteTableDefRouteCall extends AiohttpCoroutineRouteSetup, DataFlow::CallCfgNode {
    /** At what index route arguments starts, so we can handle "route" version together with get/post/... */
    int routeArgsStart;

    AiohttpRouteTableDefRouteCall() {
      exists(string decoratorName |
        decoratorName = HTTP::httpVerbLower() and
        routeArgsStart = 0
        or
        decoratorName = "route" and
        routeArgsStart = 1
      |
        this =
          API::moduleImport("aiohttp")
              .getMember("web")
              .getMember("RouteTableDef")
              .getReturn()
              .getMember(decoratorName)
              .getACall()
      )
    }

    override DataFlow::Node getUrlPatternArg() {
      result in [this.getArg(routeArgsStart + 0), this.getArgByName("path")]
    }

    override DataFlow::Node getRequestHandlerArg() { none() }

    override Function getARequestHandler() { result.getADecorator() = this.asExpr() }
  }

  /**
   * A view-class route-setup from either:
   * - `add_view` method on a `aiohttp.web.UrlDispatcher`
   * - `view` function from `aiohttp.web`
   */
  class AiohttpViewRouteSetupFromFunction extends AiohttpViewRouteSetup, DataFlow::CallCfgNode {
    AiohttpViewRouteSetupFromFunction() {
      this = urlDispathcerInstance().getMember("add_view").getACall()
      or
      this = API::moduleImport("aiohttp").getMember("web").getMember("view").getACall()
      or
      this =
        API::moduleImport("aiohttp")
            .getMember("web")
            .getMember("RouteTableDef")
            .getReturn()
            .getMember("view")
            .getACall()
    }

    override DataFlow::Node getUrlPatternArg() {
      result in [this.getArg(0), this.getArgByName("path")]
    }

    override DataFlow::Node getViewClassArg() {
      result in [this.getArg(1), this.getArgByName("handler")]
    }
  }

  /**
   * A view-class route-setup from the `view` decorator from a `aiohttp.web.RouteTableDef`.
   */
  class AiohttpViewRouteSetupFromDecorator extends AiohttpViewRouteSetup, DataFlow::CallCfgNode {
    AiohttpViewRouteSetupFromDecorator() {
      this =
        API::moduleImport("aiohttp")
            .getMember("web")
            .getMember("RouteTableDef")
            .getReturn()
            .getMember("view")
            .getACall()
    }

    override DataFlow::Node getUrlPatternArg() {
      result in [this.getArg(0), this.getArgByName("path")]
    }

    override DataFlow::Node getViewClassArg() { none() }

    override Class getViewClass() { result.getADecorator() = this.asExpr() }
  }

  /** A class that we consider a aiohttp.web View class. */
  abstract class AiohttpViewClass extends Class {
    /** Gets a function that could handle incoming requests, if any. */
    Function getARequestHandler() {
      // TODO: This doesn't handle attribute assignment. Should be OK, but analysis is not as complete as with
      // points-to and `.lookup`, which would handle `post = my_post_handler` inside class def
      result = this.getAMethod() and
      result.getName() = HTTP::httpVerbLower()
    }
  }

  /** A class that has a super-type which is a aiohttp.web View class. */
  class AiohttpViewClassFromSuperClass extends AiohttpViewClass {
    AiohttpViewClassFromSuperClass() { this.getABase() = View::subclassRef().getAUse().asExpr() }
  }

  /** A class that is used in a route-setup, therefore being considered a aiohttp.web View class. */
  class AiohttpViewClassFromRouteSetup extends AiohttpViewClass {
    AiohttpViewClassFromRouteSetup() { this = any(AiohttpViewRouteSetup rs).getViewClass() }
  }

  /** A request handler defined in an `aiohttp.web` view class, that has no known route. */
  private class AiohttpViewClassRequestHandlerWithoutKnownRoute extends HTTP::Server::RequestHandler::Range {
    AiohttpViewClassRequestHandlerWithoutKnownRoute() {
      exists(AiohttpViewClass vc | vc.getARequestHandler() = this) and
      not exists(AiohttpRouteSetup setup | setup.getARequestHandler() = this)
    }

    override Parameter getARoutedParameter() { none() }

    override string getFramework() { result = "aiohttp.web" }
  }

  // ---------------------------------------------------------------------------
  // aiohttp.web.Request taint modeling
  // ---------------------------------------------------------------------------
  /**
   * Provides models for the `aiohttp.web.Request` class
   *
   * See https://docs.aiohttp.org/en/stable/web_reference.html#request-and-base-request
   */
  module Request {
    /**
     * A source of instances of `aiohttp.web.Request`, extend this class to model new instances.
     *
     * This can include instantiations of the class, return values from function
     * calls, or a special parameter that will be set when functions are called by an external
     * library.
     *
     * Use `Request::instance()` predicate to get
     * references to instances of `aiohttp.web.Request`.
     */
    abstract class InstanceSource extends DataFlow::LocalSourceNode { }

    /** Gets a reference to an instance of `aiohttp.web.Request`. */
    private DataFlow::LocalSourceNode instance(DataFlow::TypeTracker t) {
      t.start() and
      result instanceof InstanceSource
      or
      exists(DataFlow::TypeTracker t2 | result = instance(t2).track(t2, t))
    }

    /** Gets a reference to an instance of `aiohttp.web.Request`. */
    DataFlow::Node instance() { instance(DataFlow::TypeTracker::end()).flowsTo(result) }
  }

  /**
   * A parameter that will receive a `aiohttp.web.Request` instance when a request
   * handler is invoked.
   */
  class AiohttpRequestHandlerRequestParam extends Request::InstanceSource, RemoteFlowSource::Range,
    DataFlow::ParameterNode {
    AiohttpRequestHandlerRequestParam() {
      exists(Function requestHandler |
        requestHandler = any(AiohttpCoroutineRouteSetup setup).getARequestHandler() and
        // We select the _last_ parameter for the request since that is what they do in
        // `aiohttp-jinja2`.
        // https://github.com/aio-libs/aiohttp-jinja2/blob/7fb4daf2c3003921d34031d38c2311ee0e02c18b/aiohttp_jinja2/__init__.py#L235
        //
        // I assume that is just to handle cases such as the one below
        // ```py
        // class MyCustomHandlerClass:
        //     async def foo_handler(self, request):
        //            ...
        //
        // my_custom_handler = MyCustomHandlerClass()
        // app.router.add_get("/MyCustomHandlerClass/foo", my_custom_handler.foo_handler)
        // ```
        this.getParameter() =
          max(Parameter param, int i | param = requestHandler.getArg(i) | param order by i)
      )
      or
      exists(AiohttpViewClass vc |
        // TODO
        none()
      )
    }

    override string getSourceType() { result = "aiohttp.web.Request" }
  }

  /**
   * Taint propagation for `aiohttp.web.Request`.
   *
   * See https://docs.aiohttp.org/en/stable/web_reference.html#request-and-base-request
   */
  private class AiohttpRequestAdditionalTaintStep extends TaintTracking::AdditionalTaintStep {
    override predicate step(DataFlow::Node nodeFrom, DataFlow::Node nodeTo) {
      // Methods
      //
      // TODO: When we have tools that make it easy, model these properly to handle
      // `meth = obj.meth; meth()`. Until then, we'll use this more syntactic approach
      // (since it allows us to at least capture the most common cases).
      nodeFrom = Request::instance() and
      exists(DataFlow::AttrRead attr | attr.getObject() = nodeFrom |
        // normal methods
        attr.getAttributeName() in ["clone", "get_extra_info"] and
        nodeTo.(DataFlow::CallCfgNode).getFunction() = attr
        or
        // async methods
        exists(Await await, DataFlow::CallCfgNode call |
          attr.getAttributeName() in ["read", "text", "json", "multipart", "post"] and
          call.getFunction() = attr and
          await.getValue() = call.asExpr() and
          nodeTo.asExpr() = await
        )
      )
      or
      // Attributes
      nodeFrom = Request::instance() and
      nodeTo.(DataFlow::AttrRead).getObject() = nodeFrom and
      nodeTo.(DataFlow::AttrRead).getAttributeName() in [
          "url", "rel_url", "forwarded", "host", "remote", "path", "path_qs", "raw_path", "query",
          "headers", "transport", "cookies", "content", "_payload", "content_type", "charset",
          "http_range", "if_modified_since", "if_unmodified_since", "if_range", "match_info"
        ]
    }
  }

  class AiohttpRequestMultiDictProxyInstances extends Multidict::MultiDictProxy::InstanceSource {
    AiohttpRequestMultiDictProxyInstances() {
      this.(DataFlow::AttrRead).getObject() = Request::instance() and
      this.(DataFlow::AttrRead).getAttributeName() in ["query", "headers"]
    }
  }

  class AiohttpRequestYarlUrlInstances extends Yarl::Url::InstanceSource {
    AiohttpRequestYarlUrlInstances() {
      this.(DataFlow::AttrRead).getObject() = Request::instance() and
      this.(DataFlow::AttrRead).getAttributeName() in ["url", "rel_url"]
    }
  }
}
