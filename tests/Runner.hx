import tink.http.Client;
import tink.http.Header.HeaderField;
import tink.http.Method;
import tink.http.Request;
import tink.http.Response.IncomingResponse;
import haxe.Json;

using buddy.Should;
using tink.CoreApi;

using Lambda;

typedef Target = {
  name: String, client: Client
}

@colorize
class Runner extends buddy.SingleSuite {
  
  var clients = [
    for (key in Context.clients.keys()) if (key != '')
      {name: key, client: Context.clients.get(key)}
  ];
  
  var secureClients = [
    for (key in Context.secureClients.keys()) if (key != '')
      {name: key, client: Context.secureClients.get(key)}
  ];
  
  function doRequest(client: Client, data: ClientRequest)
    return client.request(data).flatMap(response);
   
  public function new() {
    function test(target: Target) {
      var request = doRequest.bind(target.client);
      
      describe('client ${target.name}', {
        
        it('server should set the http method', function(done)
          request({url: '/'}).handle(function(res) {
            res.data.should.not.be(null);
            res.data.method.should.be(Method.GET);
            done();
          })
        );
        
        it('server should set the ip', function(done)
          request({url: '/'}).handle(function(res) {
            res.data.should.not.be(null);
            res.data.ip.should.endWith('127.0.0.1');
            done();
          })
        );
        
        it('server should set the url', function(done)
          request({url: '/uri/path?query=a&param=b'}).handle(function(res) {
            res.data.should.not.be(null);
            res.data.uri.should.be('/uri/path?query=a&param=b');
            done();
          })
        );
        
        it('server should set headers', function(done)
          request({
            url: '/uri/path?query=a&param=b', 
            headers: [
              'x-header-a' => 'a',
              'x-header-b' => '123'
            ]
          }).handle(function(res) {
            res.data.should.not.be(null);
            var headers = res.data.headers.map(function (pair)
              return '${pair.name}: ${pair.value}'
            );
            headers.should.contain('x-header-a: a');
            headers.should.contain('x-header-b: 123');
            done();
          })
        );
      
      });
    }
    
    function testSecure(target: Target) {
      var request = doRequest.bind(target.client);
      
      describe('client ${target.name}', {
        
        it('client should fetch https url', function(done)
          request({url: 'https://www.example.com'}).handle(function(res) {
            res.body.should.contain('Example Domain');
            done();
          })
        );
      
      });
    }
    
    describe('tink_http', {
      for (target in clients) test(target);
      for (target in secureClients) testSecure(target);
    });
  }
  
  function response(res: IncomingResponse): Future<{data: Data, res: IncomingResponse, body: String}>
    return IncomingResponse.readAll(res).map(function (o) 
      return switch o {
        case Success(bytes):
          var body = bytes.toString();
          var data = null;
          try 
            data = Json.parse(body)
          catch (e: Dynamic) {}
          {data: data, res: res, body: body}
        default:
          {data: null, res: res, body: null}
      }
    );
    
}