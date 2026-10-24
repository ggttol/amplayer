import Foundation
import Testing
@testable import MP9Sources

@Test func webDAVMultistatus() {
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response><D:href>/dav/music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
      <D:response><D:href>/dav/music/%E5%91%A8%E6%9D%B0%E4%BC%A6/</D:href><D:propstat><D:prop><D:displayname>周杰伦</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
      <D:response><D:href>http://nas:5005/dav/music/a%20b.flac</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>12345</D:getcontentlength></D:prop></D:propstat></D:response>
    </D:multistatus>
    """
    let entries = WebDAVResponseParser.parse(Data(xml.utf8))
    #expect(entries.count == 3)
    #expect(entries[1].isCollection)
    #expect(entries[1].displayName == "周杰伦")
    #expect(WebDAVSource.path(fromHref: entries[1].href) == "/dav/music/周杰伦/")
    #expect(WebDAVSource.path(fromHref: entries[2].href) == "/dav/music/a b.flac")
    #expect(entries[2].contentLength == 12345)
    #expect(!entries[2].isCollection)
}

@Test func didlLite() {
    let didl = """
    <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
    <container id="64$1" parentID="64" restricted="1"><dc:title>Albums</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>
    <item id="64$1$0" parentID="64$1" restricted="1"><dc:title>Song &amp; Dance</dc:title><upnp:artist>Band</upnp:artist><upnp:album>LP</upnp:album>
    <upnp:originalTrackNumber>3</upnp:originalTrackNumber><upnp:class>object.item.audioItem.musicTrack</upnp:class>
    <res size="4000000" duration="0:03:25.500" protocolInfo="http-get:*:audio/flac:*">http://192.168.1.2:8200/MediaItems/22.flac</res></item>
    </DIDL-Lite>
    """
    let entries = DIDLParser.parse(didl)
    #expect(entries.count == 2)
    #expect(entries[0].item.kind == .directory)
    #expect(entries[0].item.path == "64$1")
    let song = entries[1]
    #expect(song.item.title == "Song & Dance")
    #expect(song.item.artist == "Band")
    #expect(song.item.trackNumber == 3)
    #expect(song.item.duration == 205.5)
    #expect(song.item.fileExtension == "flac")
    #expect(song.resourceURL == "http://192.168.1.2:8200/MediaItems/22.flac")
}

@Test func deviceDescription() {
    let xml = """
    <root xmlns="urn:schemas-upnp-org:device-1-0"><device><friendlyName>NAS</friendlyName><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/ctl/CM</controlURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/ctl/ContentDir</controlURL></service>
    </serviceList></device></root>
    """
    let services = DeviceDescriptionParser.parse(Data(xml.utf8))
    #expect(services.count == 2)
    #expect(services[1].controlURL == "/ctl/ContentDir")
}

@Test func subsonicTokenAuth() throws {
    let source = SubsonicSource(config: SourceConfig(kind: .subsonic, name: "x", url: "https://music.example.com/", username: "me"), password: "secret")
    let url = try source.endpoint("ping")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(url.path == "/rest/ping.view")
    #expect(dict["u"] == "me")
    #expect(dict["t"]?.count == 32)
    #expect(dict["s"]?.isEmpty == false)
    #expect(dict["f"] == "json")
}

@Test func ssdpHeader() {
    let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.5:8200/rootDesc.xml\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n"
    #expect(LANDiscovery.header("location", in: response) == "http://192.168.1.5:8200/rootDesc.xml")
}

@Test func configBaseURL() throws {
    #expect(try SourceConfig(kind: .webdav, name: "x", url: "nas.local:5005/dav/").baseURL().absoluteString == "http://nas.local:5005/dav")
    #expect(try SourceConfig(kind: .smb, name: "x", url: "192.168.1.2/Music").baseURL().scheme == "smb")
}

@Test func pkceChallenge() {
    // RFC 7636 附录 B 的示例
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}
