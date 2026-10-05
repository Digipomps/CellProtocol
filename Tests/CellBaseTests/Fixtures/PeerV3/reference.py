#!/usr/bin/env python3
"""Independent peer-v3 reference v1. Python stdlib + system OpenSSL EVP.
Synthetic keys only. No Swift output is an input to this generator.
Run: python3 reference.py > vectors.json
"""
import base64, ctypes as c, ctypes.util, hashlib, hmac, json, sys
from pathlib import Path
for library in [ctypes.util.find_library('crypto'), '/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib']:
    try:
        lib = c.CDLL(library)
        if hasattr(lib, 'EVP_PKEY_new_raw_private_key_ex'): break
    except OSError: pass
else: raise RuntimeError('An already installed OpenSSL 3 library is required')
def fn(name, result, args):
    f = getattr(lib, name); f.restype = result; f.argtypes = args; return f
ptr = c.c_void_p; ip = c.POINTER(c.c_int); zp = c.POINTER(c.c_size_t)
newkey = fn('EVP_PKEY_new_raw_private_key_ex', ptr, [ptr,c.c_char_p,ptr,ptr,c.c_size_t])
getpub = fn('EVP_PKEY_get_raw_public_key', c.c_int, [ptr,ptr,zp])
mdnew = fn('EVP_MD_CTX_new',ptr,[]); mdfree = fn('EVP_MD_CTX_free',None,[ptr])
signinit = fn('EVP_DigestSignInit',c.c_int,[ptr,ptr,ptr,ptr,ptr])
signfn = fn('EVP_DigestSign',c.c_int,[ptr,ptr,zp,ptr,c.c_size_t])
ctxnew = fn('EVP_CIPHER_CTX_new',ptr,[]); ctxfree=fn('EVP_CIPHER_CTX_free',None,[ptr])
cipher = fn('EVP_chacha20_poly1305',ptr,[])()
init = fn('EVP_EncryptInit_ex',c.c_int,[ptr,ptr,ptr,ptr,ptr])
update = fn('EVP_EncryptUpdate',c.c_int,[ptr,ptr,ip,ptr,c.c_int])
final = fn('EVP_EncryptFinal_ex',c.c_int,[ptr,ptr,ip]); ctrl = fn('EVP_CIPHER_CTX_ctrl',c.c_int,[ptr,c.c_int,c.c_int,ptr])
def pub(key):
    out=c.create_string_buffer(32); n=c.c_size_t(32); assert getpub(key,out,c.byref(n))==1; return out.raw[:n.value]
def sign(key,data,algorithm='EdDSA'):
    ctx=mdnew(); out=c.create_string_buffer(256); n=c.c_size_t(256)
    try:
        assert signinit(ctx,None,None if algorithm=='EdDSA' else sha256(),None,key)==1
        assert signfn(ctx,out,c.byref(n),data,len(data))==1
        return out.raw[:n.value]
    finally: mdfree(ctx)
def seal(key,nonce,aad,data):
    ctx=ctxnew(); n=c.c_int(); out=c.create_string_buffer(len(data)+16); tag=c.create_string_buffer(16)
    try:
        assert init(ctx,cipher,None,key,nonce)==1
        assert update(ctx,None,c.byref(n),aad,len(aad))==1
        assert update(ctx,out,c.byref(n),data,len(data))==1
        ciphertext=out.raw[:n.value]
        assert final(ctx,out,c.byref(n))==1
        assert ctrl(ctx,0x10,16,tag)==1
        return ciphertext+tag.raw
    finally: ctxfree(ctx)
sha256 = fn('EVP_sha256',ptr,[])
decodekey = fn('d2i_AutoPrivateKey',ptr,[ptr,c.POINTER(ptr),c.c_long])
octets = fn('EVP_PKEY_get_octet_string_param',c.c_int,[ptr,c.c_char_p,ptr,c.c_size_t,zp])
def ec_key(seed):
    # SEC1 ECPrivateKey, private scalar plus explicit named-curve OID P-256.
    der=bytes.fromhex('30310201010420')+seed+bytes.fromhex('a00a06082a8648ce3d030107')
    buf=c.create_string_buffer(der); cursor=ptr(c.addressof(buf))
    key=decodekey(None,c.byref(cursor),len(der)); assert key
    return key
def ec_pub(key,compressed):
    buf=c.create_string_buffer(65); n=c.c_size_t()
    assert octets(key,b'pub',buf,65,c.byref(n))==1
    raw=buf.raw[:n.value]; assert len(raw)==65
    return bytes([2+(raw[-1]&1)])+raw[1:33] if compressed else raw
signature_path=Path(__file__).with_name('p256-signatures.json')
fixed_signatures=json.loads(signature_path.read_text()) if signature_path.exists() else {}
def C(v): return json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
def B(v): return base64.b64encode(v).decode()
def H(v): return hashlib.sha256(v).digest()
def U(n,w=4): return n.to_bytes(w,'big')
P='org.haven.bridge-peer-channel.v3'
V={}
def record(name,data): V[name]=B(data); return data
def F(label,*values):
    def lp(v): return U(len(v))+v
    value=lp(P.encode())+lp(label.encode())+U(len(values))+b''.join(map(lp,values))
    return value
def env(name,body): return C({'&string':C(body).decode(),'cid':0,'cmd':'channelAuthPeerV3'+name})
def pad(value,size):
    data=C(value); assert 0<len(data)<=size-4
    return U(len(data))+data+b'\0'*(size-4-len(data))
def mac(key,data): return hmac.digest(key,data,'sha256')
def make_vectors(algorithms=("EdDSA","EdDSA"), compressed=(True,False)):
    V.clear()
    seeds=[bytes(range(32)),bytes(range(32,64))]
    keys=[newkey(None,b'ED25519',None,x,32) if algorithms[i]=='EdDSA' else ec_key(x) for i,x in enumerate(seeds)]
    dh=[bytes.fromhex(x) for x in ['77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a','5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb']]
    dhpub=[pub(newkey(None,b'X25519',None,x,32)) for x in dh]
    ids=[{'uuid':name,'algorithm':algorithms[i],'curve':'Curve25519' if algorithms[i]=='EdDSA' else 'P-256','publicKey':B(pub(keys[i]) if algorithms[i]=='EdDSA' else ec_pub(keys[i],compressed[i]))} for i,name in enumerate(['synthetic-I/æ\n"','synthetic-R/ø\t"'])]
    endpoint={'initiator':'endpoint-I/æ\n"','responder':'endpoint-R/ø\t"','setupID':'33333333-3333-4333-8333-333333333333','domain':'nearby/é\n"'}
    hellos=[{'profile':P,'role':role,'ephemeralPublicKey':B(dhpub[i]),'nonce':B(bytes([0x11*(i+1)])*32),'generation':generation,'issuedAtMilliseconds':1800000000125+125*i} for i,(role,generation) in enumerate([('initiator','11111111-1111-4111-8111-111111111111'),('responder','22222222-2222-4222-8222-222222222222')])]
    for i in range(2):
        record('seed'+str(i),seeds[i]); record('dh'+str(i),dh[i]); record('hello'+str(i),C(hellos[i])); record('identity'+str(i),C(ids[i]))
    record('endpoint',C(endpoint))
    w1=record('W1',env('Hello',hellos[0]))
    t1=record('T1',H(record('F-wire-1',F('wire-1',w1))))
    t0=record('T0',H(record('F-clear-2',F('clear-2',t1,C(hellos[1])))))
    z=record('Z',bytes.fromhex('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'))
    prk=record('PRK',mac(t0,z))
    def K(label,i,context):
        info=record('info-'+label+str(i),F('kdf',label.encode(),['initiator-to-responder','responder-to-initiator'][i].encode(),context,U(32,2)))
        return record(label+str(i),mac(prk,info+b'\x01'))
    kh=[K('handshake-key',i,t0) for i in range(2)]; kid=[K('identity-mac-key',i,t0) for i in range(2)]
    def auth(i,previous=None):
        role=hellos[i]['role']; d={'profile':P,'signer':role,'helloDigest':t0.hex(),'endpoint':endpoint,'identity':ids[i]}
        if i==0: d.update(previousDigest=previous.hex(),peerIdentity=ids[1])
        encoded=record('D'+str(i),C(d)); digest=H(encoded).hex()
        ch={'type':'org.haven.cellprotocol.identity-signing-challenge','version':1,'purpose':'identity-origin-proof','identityUUID':ids[i]['uuid'],'publicKeyFingerprint':ids[i]['algorithm']+':'+ids[i]['curve']+':'+ids[i]['publicKey'],'domain':endpoint['domain'],'resource':P+':'+digest,'action':'openPeerBridgeChannel','audience':P+':'+H(C(endpoint)).hex(),'nonce':hellos[1-i]['nonce'],'issuedAt':1800000000.125,'expiresAt':1800000030.125}
        signing=record('challenge'+str(i),C(ch))
        if algorithms[i]=='EdDSA': signature=sign(keys[i],signing)
        else:
            cachekey=H(ids[i]['publicKey'].encode()+signing).hex()
            if cachekey not in fixed_signatures: fixed_signatures[cachekey]=B(sign(keys[i],signing,algorithms[i]))
            signature=base64.b64decode(fixed_signatures[cachekey])
        record('signature'+str(i),signature)
        core={'endpoint':endpoint,'identity':ids[i],'proof':{'sessionID':endpoint['setupID'],'generation':hellos[1-i]['generation'],'signature':B(signature)}}
        record('Core'+str(i),C(core)); authmac=record('identityMAC'+str(i),mac(kid[i],record('F-identity'+str(i),F('identity-mac',role.encode(),t0 if i else previous,C(core)))))
        a=dict(core,identityMAC=B(authmac)); record('Auth'+str(i),C(a)); return a,digest
    def encrypted(step,value,size,context,i):
        padded=record('pad'+str(step),pad(value,size)); nonce=record('nonce'+str(step),b'\0'*4+U(0 if step<4 else 1,8))
        aad=record('aad'+str(step),F('handshake-aead',str(step).encode(),context))
        return record('sealed'+str(step),seal(kh[i],nonce,aad,padded))
    ar,dr=auth(1)
    w2=record('W2',env('ResponderAuth',{'hello':hellos[1],'sealed':B(encrypted(2,ar,8192,t0,1))}))
    t2=record('T2',H(record('F-wire-2',F('wire-2',t0,w2))))
    ai,di=auth(0,t2)
    w3=record('W3',env('InitiatorAuth',{'profile':P,'sealed':B(encrypted(3,ai,8192,t2,0))}))
    t3=record('T3',H(record('F-wire-3',F('wire-3',t2,w3))))
    kfin=[K('finished-key',i,t3) for i in range(2)]
    def finished(step,context,i,digest):
        ack={'sessionID':endpoint['setupID'],'generation':hellos[i]['generation'],'transcriptDigest':digest}
        record('ack'+str(step),C(ack))
        verify=record('verify'+str(step),mac(kfin[i],record('F-finished'+str(step),F('finished',str(step).encode(),context,C(ack)))))
        return {'ack':ack,'verifyData':B(verify)}
    w4=record('W4',env('ResponderFinished',{'profile':P,'sealed':B(encrypted(4,finished(4,t3,1,di),1024,t3,1))}))
    t4=record('T4',H(record('F-wire-4',F('wire-4',t3,w4))))
    w5=record('W5',env('InitiatorFinished',{'profile':P,'sealed':B(encrypted(5,finished(5,t4,0,dr),1024,t4,0))}))
    t5=record('T5',H(record('F-wire-5',F('wire-5',t4,w5))))
    kapp=[K('application-key',i,t5) for i in range(2)]
    for i in range(2):
        for counter in range(2):
            message=b'N22 vector' if counter==0 else b'N22 secret'
            header=b'HPC3'+hellos[i]['generation'].encode()+bytes([i])+U(counter,8)
            aad=(P+'\0record\0').encode()+header
            record('record'+str(i)+str(counter),header+seal(kapp[i],b'\0'*4+U(counter,8),aad,message))
    return V
if __name__=='__main__':
    if '--all' in sys.argv:
        for name,algorithms,compressed in [('vectors',('EdDSA','EdDSA'),(True,False)),('p256',('ECDSA','ECDSA'),(True,False)),('mixed-i',('ECDSA','EdDSA'),(False,True)),('mixed-r',('EdDSA','ECDSA'),(True,True))]:
            Path(__file__).with_name(name+'.json').write_text(json.dumps(make_vectors(algorithms,compressed),sort_keys=True,indent=2)+'\n')
        signature_path.write_text(json.dumps(fixed_signatures,sort_keys=True,indent=2)+'\n')
    else: print(json.dumps(make_vectors(),sort_keys=True,indent=2))
