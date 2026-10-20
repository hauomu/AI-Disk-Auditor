"""Exercise the published standalone entry points against real binary headers."""
import base64
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

REPO=Path(__file__).resolve().parents[1]
def gguf(path, metadata, endian='<'):
    def text(s):
        b=s.encode();return struct.pack(endian+'Q',len(b))+b
    data=b'GGUF'+struct.pack(endian+'IQQ',3,0,len(metadata))
    for key,value in metadata.items():
        kind=8 if isinstance(value,str) else 9 if isinstance(value,tuple) else 4
        data+=text(key)+struct.pack(endian+'I',kind)
        data+=text(value) if kind==8 else struct.pack(endian+'IQ',4,value[1])+b'\0'*(4*value[1]) if kind==9 else struct.pack(endian+'I',value)
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes(data)

class ModelInventory(unittest.TestCase):
    def setUp(self):
        self.base=Path(tempfile.mkdtemp(prefix='model-inventory-',dir=REPO.parent))
        self.store=self.base/'models';self.store.mkdir()
        self.env=os.environ.copy()
        for k in list(self.env):
            if k.startswith(('AI_AUDIT_','HF_','HUGGINGFACE_','UV_','OLLAMA_','TORCH_','XDG_','VLLM_')):self.env.pop(k)
        for k in ('HOME','USERPROFILE','LOCALAPPDATA','APPDATA','ProgramData','ProgramFiles','TEMP','TMP'):
            p=self.base/k;p.mkdir();self.env[k]=str(p)
    def run_audit(self,extra=''):
        if os.name=='nt':
            q=lambda s:"'"+str(s).replace("'","''")+"'"
            code='[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & ([scriptblock]::Create([IO.File]::ReadAllText('+q(REPO/'windows/ai-disk-audit.ps1')+'))) -HomeOnly -Root '+q(self.store)+' '+extra
            cmd=[shutil.which('powershell'),'-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(code.encode('utf-16le')).decode()]
        else:cmd=['bash',str(REPO/'linux/ai-disk-audit.sh'),'--home-only','--root',str(self.store)]+extra.split()
        r=subprocess.run(cmd,env=self.env,text=True,capture_output=True,encoding='utf-8',timeout=60)
        self.assertEqual(r.returncode,0,r.stderr)
        return r.stdout
    def test_metadata_roles_backends_gateways_and_manifest(self):
        gguf(self.store/'models--Uploader--Repository'/'snapshots'/'rev'/'weights-Q8_0.gguf',{'general.name':'Fixture Model','general.organization':'Declared Author','general.quantized_by':'Quantizer','general.architecture':'llama','tokenizer.fixture':('array',600001),'general.file_type':15,'llama.nextn_predict_layers':2})
        gguf(self.store/'mmproj.gguf',{'general.type':'mmproj','general.architecture':'clip','general.file_type':1},'>')
        gguf(self.store/'test-mtp-Q4_K_M.gguf',{'general.file_type':15})
        gguf(self.store/'split-00001-of-00002.gguf',{'general.file_type':18,'general.name':'Split model'})
        gguf(self.store/'split-00002-of-00002.gguf',{})
        (self.store/'ngram-table.bin').write_bytes(b'fixture')
        (self.store/'libggml-vulkan.so').write_bytes(b'fixture')
        (self.store/'gateway.py').write_text('raise RuntimeError("must never execute")')
        (self.store/'.env').write_text('SECRET_SENTINEL_DO_NOT_REPORT=hidden')
        digest='a'*64;blob=self.store/'ollama'/'blobs'/('sha256-'+digest)
        gguf(blob,{'general.name':'Manifest Model','general.file_type':2})
        manifest=self.store/'ollama'/'manifests'/'registry.ollama.ai'/'library'/'fixture'/'latest'
        manifest.parent.mkdir(parents=True);manifest.write_text(json.dumps({'layers':[{'mediaType':'application/vnd.ollama.image.model','digest':'sha256:'+digest}]}))
        out=self.run_audit()
        for value in ('Fixture Model','Declared Author','Quantizer','Q4_K_M [GGUF]','filename hint: Q8_0','Uploader/Repository','multimodal projector/encoder [GGUF]','MTP sidecar candidate','n-gram table candidate','Vulkan','gateway.py','Ollama manifest:','Manifest Model','MTP capability:','inherited from first-shard GGUF'):
            self.assertIn(value,out)
        self.assertNotIn('SECRET_SENTINEL',out)
    def test_safetensors_config_corruption_and_opt_out(self):
        folder=self.store/'tensor-model';folder.mkdir()
        header=json.dumps({'tensor':{'dtype':'BF16','shape':[1],'data_offsets':[0,2]}}).encode()
        (folder/'model.safetensors').write_bytes(struct.pack('<Q',len(header))+header+b'00')
        (folder/'config.json').write_text(json.dumps({'model_type':'fixture-arch','quantization_config':{'quant_method':'awq','bits':4}}))
        (self.store/'broken.gguf').write_bytes(b'GGUF'+struct.pack('<IQQ',3,0,2)+struct.pack('<Q',2**63))
        out=self.run_audit()
        for value in ('BF16 [header','awq 4-bit [config]','fixture-arch','Metadata note:'):self.assertIn(value,out)
        out=self.run_audit('-NoInventory' if os.name=='nt' else '--no-inventory')
        self.assertNotIn('Model files and sidecars',out)
    @unittest.skipIf(os.name=='nt','Unix filename fallback')
    def test_no_python_filename_fallback(self):
        binpath=self.base/'bin';binpath.mkdir()
        for name in ('bash','uname','du','awk','sort','find','df','stat'):
            target=shutil.which(name)
            if target:(binpath/name).symlink_to(target)
        (self.store/'mmproj-F16.gguf').write_bytes(b'fixture')
        self.env['PATH']=str(binpath)
        self.assertIn('multimodal projector candidate [filename]',self.run_audit())

if __name__=='__main__':unittest.main()
