import chronos
import chronos/streams/[tlsstream], chronos/transports/datagram
import std/[strformat, net, openssl, random]
import overrides/[asyncnet]
import print, connection, pipe
from globals import nil

type
    ServerConnectionPoolContext = object
        listeners_udp: UdpConnections
        pending_free_outbounds: int
        up_bounds: Connections
        dw_bounds: Connections
        outbounds: Connections
        log_lock: AsyncLock

var context = ServerConnectionPoolContext()



proc generateFinishHandShakeData(upload: bool): string =
    #AES default chunk size is 16 so use a multple of 16
    let rlen: uint16 = uint16(globals.full_tls_record_len.int + 16*(6+rand(4)))
    var random_trust_data: string = newStringOfCap(rlen)
    random_trust_data.setLen(rlen)

    copyMem(addr random_trust_data[0], addr(globals.random_str[rand(250)]), rlen)
    copyMem(addr random_trust_data[0], addr globals.tls13_record_layer[0], 3) #tls header
    copyMem(addr random_trust_data[3], addr rlen, 2) #tls len

    let base = 5 + 7 + `mod`(globals.sh5, 7.uint8)
    copyMem(unsafeAddr random_trust_data[base+0], unsafeAddr globals.sh1, 4)
    copyMem(unsafeAddr random_trust_data[base+4], unsafeAddr globals.sh2, 4)
    var up: uint8 = (if upload: 1+rand(uint8.high.int-1) else: 0x0).uint8

    up = up xor globals.sh5


    copyMem(unsafeAddr random_trust_data[base+8], unsafeAddr up, 1)

    return random_trust_data

proc monitorData(data: string): bool =
    try:
        if len(data) < 16: return false
        let base = 5 + 7 + `mod`(globals.sh5, 7.uint8)
        var sh3_c: uint32
        var sh4_c: uint32
        copyMem(unsafeAddr sh3_c, unsafeAddr data[base+0], 4)
        copyMem(unsafeAddr sh4_c, unsafeAddr data[base+4], 4)
        let chk1 = sh3_c == globals.sh3
        let chk2 = sh4_c == globals.sh4
        return chk1 and chk2
    except:
        return false

proc remoteTrusted(port: Port): Future[Connection] {.async.} =
    var con = await connection.connect(initTAddress(globals.next_route_addr, port))
    con.trusted = TrustStatus.yes
    return con

proc acquireClientConnection(upload: bool): Future[Connection] {.async.} =
    var found: Connection = nil
    var source: Connections = if upload: context.up_bounds else: context.dw_bounds

    for i in 0..<50:
        found = source.roundPick()
        if found != nil:
            if found.closed or found.isClosing:
                source.remove(found)
                continue

            return found


    return nil

proc processConnection(client: Connection) {.async.} =


    proc closeLine(client: Connection, remote: Connection) {.async.} =
        if globals.log_conn_destory: echo "closed client & remote"
        if remote != nil:
            await allFutures(remote.closeWait(), client.closeWait())
        else:
            await client.closeWait()


    proc processUdpRemote(remote: UdpConnection) {.async.} =
        var client = await acquireClientConnection(true)

        let width = globals.full_tls_record_len.int + globals.mux_record_len.int

        try:
            #read
            var pbytes = remote.transp.getMessage()
            var nbytes = len(pbytes)
            if nbytes > 0:
                var data = newStringOfCap(cap = nbytes + width); data.setlen(nbytes + width)
                copyMem(addr data[0 + width], addr pbytes[0], nbytes)
                if globals.log_data_len: echo &"[processUdpRemote] {nbytes} bytes from remote {client.id} (udp)"

                #write
                if client.closed:
                    client = await acquireClientConnection(true)
                    if client == nil:
                        if globals.log_conn_error: echo "[Error] no client for udp !"
                        return

                packForSend(data, remote.id, remote.port.uint16, flags = {DataFlags.udp})
                await client.twriter.write(data)
                if globals.log_data_len: echo &"[processUdpRemote] Sent {data.len()} bytes ->  client (udp)"

        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()


    proc processRemote(remote: Connection) {.async.} =
        var client = await acquireClientConnection(true)
        if client == nil:
            if globals.log_conn_error: echo "[Error] no client for tcp !"
            return
        var data = newStringOfCap(4200)
        try:
            while not remote.closed:
                #read
                data.setlen remote.reader.tsource.offset
                if data.len() == 0:
                    if remote.reader.atEof():
                        break
                    else:
                        discard await remote.reader.readOnce(addr data, 0)
                        continue

                let width = globals.full_tls_record_len.int + globals.mux_record_len.int
                data.setLen(data.len() + width)
                await remote.reader.readExactly(addr data[0 + width], data.len - width)

                if client.closed or client.isClosing:
                    client = await acquireClientConnection(true)
                    if client == nil:
                        if globals.log_conn_error: echo "[Error] no client for tcp !"
                        break

                # echo "before enc:  ", data[10 .. data.high].hash(), "  len:",data.len
                packForSend(data, remote.id, remote.port.uint16)

                await client.twriter.write(data)
                if globals.log_data_len: echo &"[processRemote] Sent {data.len()} bytes ->  client"

        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()

        #close
        if not remote.flag_no_close_signal:
            try:
                if client == nil or client.closed:
                    client = await acquireClientConnection(true)
                if client != nil:
                    await client.twriter.write(closeSignalData(remote.id))
            except:
                if globals.log_conn_error: echo getCurrentExceptionMsg()

        context.outbounds.remove(remote)
        remote.close()

    proc proccessClient() {.async.} =
        var data = newStringOfCap(4200)
        var boundary: uint16 = 0
        var cid: uint16
        var port: uint16
        var flag: uint8
        var dec_bytes_left: uint

        try:
            while not client.closed:
                #read
                data.setlen client.treader.tsource.offset
                if data.len() == 0:
                    if client.treader.atEof():
                        break
                    else:
                        discard await client.treader.readOnce(addr data, 0); continue


                if boundary == 0:
                    let width = int(globals.full_tls_record_len + globals.mux_record_len)
                    data.setLen width
                    await client.treader.readExactly(addr data[0], width)
                    copyMem(addr boundary, addr data[3], sizeof(boundary))
                    if boundary == 0: break
                    copyMem(addr cid, addr data[globals.full_tls_record_len], sizeof(cid))
                    copyMem(addr port, addr data[globals.full_tls_record_len.int + sizeof(cid)], sizeof(port))
                    copyMem(addr flag, addr data[globals.full_tls_record_len.int + sizeof(cid) + sizeof(port)], sizeof(flag))
                    cid = cid xor boundary
                    port = port xor boundary
                    flag = flag xor boundary.uint8
                    boundary -= globals.mux_record_len.uint16
                    if boundary == 0:
                        context.outbounds.with(cid, child_remote):
                            child_remote.flag_no_close_signal = true
                            context.outbounds.remove(child_remote)
                            child_remote.close()
                            if globals.log_conn_destory: echo "close mux client"
                    else:
                        dec_bytes_left = min(globals.fast_encrypt_width, boundary)
                    continue
                let readable = min(boundary, data.len().uint16)
                boundary -= readable; data.setlen readable
                await client.treader.readExactly(addr data[0], readable.int)
                if globals.log_data_len: echo &"[proccessClient] {data.len()} bytes from client"


                if DataFlags.junk in cast[TransferFlags](flag):
                    if globals.log_data_len: echo &"[proccessClient] {data.len()} discarded from client"
                    continue

                if dec_bytes_left > 0:
                    let consumed = min(data.len(), dec_bytes_left.int)
                    dec_bytes_left -= consumed.uint
                    unPackForRead(data, consumed)

                #write
                # echo "before dec:" ,data[0 .. 10].repr
                # unPackForRead(data)
                # echo "after dec:", data.hash


                if DataFlags.udp in cast[TransferFlags](flag):
                    proc handleDatagram(transp: DatagramTransport,
                        raddr: TransportAddress): Future[void] {.async.} =
                        var (found, connection) = findUdp(context.listeners_udp, transp.fd)
                        if found:
                            await processUdpRemote(connection)

                    if context.listeners_udp.hasID(cid):
                        context.listeners_udp.with(cid, udp_remote):
                            udp_remote.hit()
                            await udp_remote.transp.send(data)
                            if globals.log_data_len: echo &"[proccessClient] {data.len()} bytes -> remote (presist udp)"

                    else:
                        let ta = initTAddress(globals.next_route_addr, if globals.multi_port: port.Port else: globals.next_route_port)
                        var transp = newDatagramTransport(handleDatagram, remote = ta)

                        var connection = UdpConnection.new(transp, ta)

                        connection.id = cid
                        context.listeners_udp.register connection
                        await connection.transp.send(data)
                        if globals.log_data_len: echo &"[proccessClient] {data.len()} bytes -> remote (udp)"
                        asyncSpawn connection.transp.join()

                else:
                    if context.outbounds.hasID(cid):
                        context.outbounds.with(cid, child_remote):
                            if not isSet(child_remote.estabilished): await child_remote.estabilished.wait()
                            if not child_remote.closed():
                                try:
                                    await child_remote.writer.write(data) 
                                except :
                                    echo "X1"
                                    echo getCurrentExceptionMsg()
                    else:
                        var remote = await remoteTrusted(if globals.multi_port: port.Port else: globals.next_route_port)
                        remote.id = cid
                        context.outbounds.register(remote)
                        asyncSpawn processRemote(remote)
                        try:
                            await remote.writer.write(data) 
                        except :
                            echo "X2"
                            echo getCurrentExceptionMsg()
                        if globals.log_data_len: echo &"[proccessClient] {data.len()} bytes -> remote"

        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()

        #close
        context.dw_bounds.remove(client)
        # poolFrame()

        await client.closeWait()


        # await closeLine(client, remote)


    try:
        asyncSpawn proccessClient()
    except:
        print getCurrentExceptionMsg()




proc poolConttroller() {.async.} =
    proc handleUpClient(client: Connection){.async.} =
        try:
            let bytes = await client.treader.consume()
            when not defined release:
                echo "discarded ", bytes, " bytes form up-bound."
        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()
        when not defined release:
            echo "closed a up-bound"
        context.up_bounds.remove(client)
        client.close


    proc connect(upload: bool) {.async.} =
        inc context.pending_free_outbounds
        try:
            var con_fut = connect(initTAddress(globals.iran_addr, globals.iran_port), SocketScheme.Secure, globals.final_target_domain)
            var notimeout = await withTimeout(con_fut, 3.secs)
            if notimeout:
                var conn = con_fut.read()
                if globals.log_conn_create: echo "TlsHandsahke complete."
                conn.trusted = TrustStatus.yes

                await conn.twriter.write(generateFinishHandShakeData(upload))

                if upload:
                    context.up_bounds.add conn
                    asyncSpawn handleUpClient(conn)
                else:
                    context.dw_bounds.add conn
                    asyncSpawn processConnection(conn)

            else:
                if globals.log_conn_create: echo "Connecting to iran Timed-out!"

        except TLSStreamProtocolError as exc:
            if globals.log_conn_create: echo "Tls error, handshake failed because:"
            echo exc.msg

        except CatchableError as exc:
            if globals.log_conn_create: echo "Connection failed because:"
            echo exc.name, ": ", exc.msg

        dec context.pending_free_outbounds

    proc reCreate() {.async.} =
        var u_futs: seq[Future[void]]
        var d_futs: seq[Future[void]]
        if context.up_bounds.len().uint <= globals.upload_cons:
            for i in 0..<globals.upload_cons:
                u_futs.add connect(true)
        await all u_futs
        if context.dw_bounds.len().uint <= globals.download_cons:
            for i in 0..<globals.download_cons:
                d_futs.add connect(false)
        await all d_futs


    proc watch(): Future[bool] {.async.} =
        if context.up_bounds.len().uint < 2 or context.dw_bounds.len().uint < 2:
            await context.log_lock.acquire()
            stdout.write "[Warn] few connections exist!, retry to connect in 3 seconds."; stdout.flushFile()
            for i in 0..<3:
                stdout.write "."; await sleepAsync 1.seconds; stdout.flushFile();
            stdout.write '\n'; context.log_lock.release()
            return true
        else:
            return false


    while true:
        await reCreate()
        var secs_left = (globals.connection_age - globals.connection_rewind).int
        while true:
            await sleepAsync 1.seconds; dec secs_left
            if await watch():
                break
            if secs_left <= 0: break
        # if  context.up_bounds.len().uint < 2 or context.up_bounds.len().uint < 2:
        #     await context.log_lock.acquire()
        #     stdout.write "[Warn] few connections exist!, retry to connect in 3 seconds."; stdout.flushFile()
        #     for i in 0..<3:
        #         stdout.write "."; await sleepAsync (1).seconds; stdout.flushFile();
        #     stdout.write '\n'; context.log_lock.release()
        # else:
        #     await sleepAsync ((globals.connection_age - globals.connection_rewind).int).seconds


proc start*(){.async.} =
    echo &"Mode Foreign Server:  {globals.self_ip} <-> {globals.iran_addr} ({globals.final_target_domain} with ip {globals.final_target_ip})"
    context.listeners_udp.new()
    context.outbounds.new()
    context.up_bounds.new()
    context.dw_bounds.new()
    context.log_lock = newAsyncLock()

    trackOldConnections(context.up_bounds, globals.connection_age + globals.connection_rewind)
    trackOldConnections(context.dw_bounds, globals.connection_age + globals.connection_rewind)


    trackDeadUdpConnections(context.listeners_udp, globals.udp_max_idle_time, true)

    asyncSpawn poolConttroller()
    while true:
        await sleepAsync(5.secs)
        await context.log_lock.acquire()
        echo "prallel upload: ", context.up_bounds.len, "   ",
             "parallel download: ", context.dw_bounds.len, "   ",
             "outbounds: ", context.outbounds.len
        context.log_lock.release()



    # await sleepAsync(2.secs)
    # poolFrame()

