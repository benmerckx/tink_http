package tink.http;

import haxe.DynamicAccess;
import tink.io.Sink;
import tink.io.Source;
import tink.io.StreamParser;
import tink.http.Message;
import tink.http.Header;
import tink.http.Request;
import tink.http.Response;
import tink.io.Worker;
import tink.io.IdealSource;

#if tink_tcp
import tink.tcp.Connection;
import tink.tcp.Endpoint;
#end

#if nodejs
import js.node.http.IncomingMessage;
#end

#if (js && !nodejs)
import haxe.io.Bytes;
import js.html.XMLHttpRequest;
import js.html.Int8Array;
#end

using tink.CoreApi;
using StringTools;

@:forward
abstract Client(ClientObject) from ClientObject to ClientObject {
  
}

interface ClientObject {
  function request(req:OutgoingRequest):Future<IncomingResponse>;
}

class StdClient implements ClientObject {
  var worker:Worker;
  public function new(?worker:Worker) {
    this.worker = worker.ensure();
  }
  public function request(req:OutgoingRequest):Future<IncomingResponse> 
    return Future.async(function (cb) {
            
      var r = new haxe.Http('http:'+req.header.fullUri());
      
      function send(post) {
        var code = 200;
        r.onStatus = function (c) code = c;
        
        function headers()
          return 
            #if sys
              switch r.responseHeaders {
                case null: [];
                case v:
                  [for (name in v.keys()) 
                    new HeaderField(name, v[name])
                  ];
              }
            #else
              [];
            #end
          
        r.onError = function (msg) {
          if (code == 200) code = 500;
          worker.work(true).handle(function () {
            cb(new IncomingResponse(new ResponseHeader(code, 'error', headers()), msg));        
          });//TODO: this hack makes sure things arrive on the right thread. Great, huh?
        }
        
        r.onData = function (data) {
          
          worker.work(true).handle(function () {
            cb(new IncomingResponse(new ResponseHeader(code, 'OK', headers()), data));
          });//TODO: this hack makes sure things arrive on the right thread. Great, huh?
        }
        
        worker.work(function () r.request(post));
      }      
      
      for (h in req.header.fields)
        r.setHeader(h.name, h.value);
        
      switch req.header.method {
        case GET | HEAD | OPTIONS:
          send(false);
        default:
          req.body.all().handle(function(bytes) {
            r.setPostData(bytes.toString());
            send(true);  
        });
      }
    });
}

#if tink_tcp
class TcpClient implements ClientObject { 
  public function new() {}
  public function request(req:OutgoingRequest):Future<IncomingResponse> {
    
    var cnx = Connection.establish({ host: req.header.host.name, port: req.header.host.port });
    
    req.body.prepend(req.header.toString()).pipeTo(cnx.sink).handle(function (x) {
      cnx.sink.close();//TODO: implement connection reuse
    });
    
    return cnx.source.parse(ResponseHeader.parser()).map(function (o) return switch o {
      case Success({ data: header, rest: body }):
        new IncomingResponse(header, body);
      case Failure(e):
        new IncomingResponse(new ResponseHeader(e.code, e.message, []), (e.message : Source).append(e));
    });
  }
}
#else
@:require(tink_tcp)
extern class TcpClient implements ClientObject {
  public function new();
  public function request(req:OutgoingRequest):Future<IncomingResponse>;
}
#end 

#if nodejs

typedef NodeAgent<Opt> = {
  public function request(options:Opt, callback:IncomingMessage->Void):js.node.http.ClientRequest;
}
class NodeSecureClient extends NodeClient {
  override function request(req:OutgoingRequest):Future<IncomingResponse> {
    var options:js.node.Https.HttpsRequestOptions = {
      method: cast req.header.method,
      path: req.header.uri,
      host: req.header.host.name,
      port: req.header.host.port,
      headers: cast {
        var map = new DynamicAccess<String>();
        for (h in req.header.fields)
          map[h.name] = h.value;
        map;
      },
      agent: false,
    }
    return nodeRequest(js.node.Https, options, req);
  }
}

class NodeClient implements ClientObject {
  
  public function new() { }
  
  public function request(req:OutgoingRequest):Future<IncomingResponse> {
    var options:js.node.Http.HttpRequestOptions = {
      method: cast req.header.method,
      path: req.header.uri,
      host: req.header.host.name,
      port: req.header.host.port,
      headers: cast {
        var map = new DynamicAccess<String>();
        for (h in req.header.fields)
          map[h.name] = h.value;
        map;
      },
      agent: false,
    }
    return nodeRequest(js.node.Http, options, req);
  }
    
    
  function nodeRequest<A:NodeAgent<T>, T>(agent:A, options:T, req:OutgoingRequest):Future<IncomingResponse> 
    return 
      Future.async(function (cb) {
        var fwd = agent.request(
          options,
          function (msg:IncomingMessage) cb(new IncomingResponse(
            new ResponseHeader(
              msg.statusCode,
              msg.statusMessage,
              [for (i in 0...msg.rawHeaders.length >> 1) new HeaderField(msg.rawHeaders[2*i], msg.rawHeaders[2*i+1])]
            ),
            Source.ofNodeStream('Response from ${req.header.fullUri()}', msg)
          ))
        );
        
        function fail(e:Error)
          cb(new IncomingResponse(
            new ResponseHeader(e.code, e.message, []),
            e.message
          ));
          
        fwd.on('error', function () fail(new Error(502, 'Gateway Error')));
        
        req.body.pipeTo(
          Sink.ofNodeStream('Request to ${req.header.fullUri()}', fwd)
        ).handle(function (res) {
          fwd.end();
          req.body.close();
          switch res {
            case AllWritten:
            case SinkEnded: fail(new Error(502, 'Gateway Error'));
            case SinkFailed(e): fail(new Error(502, 'Gateway Error'));
          }
        });
      });
}
#else
@:require(nodejs)
extern class NodeClient implements ClientObject {
  public function new();
  public function request(req:OutgoingRequest):Future<IncomingResponse>;
}
#end

@:access(tink.http.containers.LocalContainer)
class LocalContainerClient implements ClientObject {
  
  var container:tink.http.containers.LocalContainer;
  public function new(container) {
    this.container = container;
  }
  
  public function request(req:OutgoingRequest):Future<IncomingResponse> {
      return container.serve(new IncomingRequest(
        '127.0.0.1',
        new IncomingRequestHeader(req.header.method, req.header.uri, 'HTTP/1.1', req.header.fields),
        Plain(req.body)
      )) >>
      function(res:OutgoingResponse) return new IncomingResponse(
        res.header,
        res.body
      );
    }
    
}
#if (js && !nodejs)
class JsSecureClient extends JsClient {
  override function request(req:OutgoingRequest):Future<IncomingResponse> {
    return jsRequest(req, switch req.header.host {
        case null: ''; // TODO: js.Browser.window.location?
        case v: 'https://$v';
    });
  }
}

class JsClient implements ClientObject {
  public function new() {}
  
  public function request(req:OutgoingRequest):Future<IncomingResponse> {
    return jsRequest(req, switch req.header.host {
        case null: ''; // TODO: js.Browser.window.location?
        case v: 'http://$v';
    });
  }
  
  function jsRequest(req:OutgoingRequest, host:String) {
    return Future.async(function(cb) {
      var http = getHttp();
      http.open(req.header.method, host + req.header.uri);
      http.responseType = ARRAYBUFFER;
      for(header in req.header.fields) http.setRequestHeader(header.name, header.value);
      http.onreadystatechange = function() if(http.readyState == 4) { // this is equivalent to onload...
        if(http.status != 0) {
          var headers = switch http.getAllResponseHeaders() {
            case null: [];
            case v: [for(line in v.split('\r\n')) {
              if(line != '') {
                var s = line.split(': ');
                new HeaderField(s[0], s.slice(1).join(': '));
              }
            }];
          }
          var header = new ResponseHeader(http.status, http.statusText, headers);
          cb(new IncomingResponse(
            new ResponseHeader(http.status, http.statusText, headers),
            switch http.response {
              case null: Empty.instance;
              case v: Bytes.ofData(v);
            }
          ));
        } else {
          cb(new IncomingResponse(
            new ResponseHeader(502, 'XMLHttpRequest Error', []),
            Empty.instance
          ));
        }
      }
      http.onerror = function() {
        cb(new IncomingResponse(
          new ResponseHeader(502, 'XMLHttpRequest Error', []),
          Empty.instance
        ));
      }
      req.body.all().handle(function(bytes) http.send(new Int8Array(bytes.getData())));
    });
  }
  
  // see: http://stackoverflow.com/a/2557268/3212365
  static var factories:Array<Void->XMLHttpRequest> = [
    function() return new XMLHttpRequest(), // browser compatibility: https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequest#Browser_compatibility
    function() return untyped __js__('new ActiveXObject("Msxml2.XMLHTTP")'),
    function() return untyped __js__('new ActiveXObject("Msxml3.XMLHTTP")'),
    function() return untyped __js__('new ActiveXObject("Microsoft.XMLHTTP")'),
  ];
  function getHttp() {
      for(f in factories) try return f() catch(e:Dynamic) {}
      throw 'No compatible XMLHttpRequest object can be found';
  }
}
#end