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
    def run_audit(self,extra='',prefix=''):
        if os.name=='nt':
            q=lambda s:"'"+str(s).replace("'","''")+"'"
            code=prefix+'[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & ([scriptblock]::Create([IO.File]::ReadAllText('+q(REPO/'windows/ai-disk-audit.ps1')+'))) -HomeOnly -Root '+q(self.store)+' '+extra
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
        for value in ('Fixture Model','Declared Author','Quantizer','Q4_K_M [GGUF]','filename hint: Q8_0','Uploader/Repository','multimodal projector/encoder [GGUF]','MTP sidecar candidate','n-gram table candidate','Vulkan','gateway.py','Ollama manifest:','Manifest Model','MTP capability:','Shards: 2/2 present; complete filename set'):
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
    def test_shards_group_before_limit_and_sizes_are_summed(self):
        for n in (1,2):
            path=self.store/('large-Q4_K_M-%05d-of-00002.gguf'%n)
            gguf(path,{'general.name':'Grouped Fixture','general.file_type':15} if n==1 else {})
            with path.open('ab') as f:f.write(b'0'*(3*1024*1024))
        (self.store/'single.gguf').write_bytes(b'0'*(4*1024*1024))
        out=self.run_audit('-ModelLimit 1' if os.name=='nt' else '--model-limit 1')
        self.assertEqual(out.count('  Model set:'),1,out)
        self.assertIn('large-Q4_K_M-*-of-00002.gguf',out)
        self.assertIn('Shards: 2/2 present; complete filename set',out)
        self.assertIn('size: 0.006 GiB',out)
        self.assertIn('Grouped Fixture',out)
        self.assertNotIn('large-Q4_K_M-00002-of-00002.gguf',out)
        self.assertNotIn('  File:',out)

    def test_missing_shards_and_distinct_sets(self):
        for dirname in ('quant-a','quant-b'):
            folder=self.store/dirname;folder.mkdir()
            for n in (1,3):gguf(folder/('same-%05d-of-00003.gguf'%n),{'general.file_type':15})
            gguf(folder/'mmproj-F16.gguf',{'general.type':'mmproj'})
        folder=self.store/'tensors';folder.mkdir()
        for n in (1,2):
            header=json.dumps({'tensor':{'dtype':'F16','shape':[1],'data_offsets':[0,2]}}).encode()
            (folder/('model-%05d-of-00002.safetensors'%n)).write_bytes(struct.pack('<Q',len(header))+header+b'00')
        out=self.run_audit()
        self.assertEqual(out.count('  Model set:'),3,out)
        self.assertEqual(out.count('Shards: 2/3 present; missing: 00002'),2,out)
        self.assertEqual(out.count('multimodal projector/encoder [GGUF]'),2,out)
        self.assertIn('Shards: 2/2 present; complete filename set',out)
        self.assertIn('Tensor dtypes: F16',out)

    def test_package_data_vocab_and_proxy_modules_are_not_models_or_gateways(self):
        for rel in ('Lib/site-packages/scipy/special/tests/data/boost.npz',
                    'uv/cache/archive-v0/random/scipy/stats/_sobol_direction_numbers.npz',
                    'Lib/site-packages/site-loader.pth','uv/cache/archive-v0/random/site-loader.pth',
                    'uv/cache/archive-v0/random/torch/fx/proxy.py',
                    'uv/cache/archive-v0/random/anthropic/types/gateway_timeout_error.py',
                    '.venv_t5_550/urllib3/util/proxy.py','test/gateway_test.py',
                    'scratch/proxy.py','notes/data.npz'):
            p=self.store/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'fixture')
        gguf(self.store/'runtime/models/ggml-vocab-gemma.gguf',{'general.name':'vocab fixture'})
        gguf(self.store/'actual-model.gguf',{'general.name':'Real Model','general.file_type':15})
        (self.store/'gateway.py').write_text('raise RuntimeError("never execute")')
        out=self.run_audit()
        model_section=out.split('=== Model files and sidecars ===',1)[1].split('=== Backend/runtime installations ===',1)[0]
        self.assertIn('Real Model',model_section)
        self.assertNotIn('ggml-vocab-',model_section)
        for noise in ('boost.npz','_sobol_direction_numbers.npz','site-loader.pth','proxy.py','gateway_timeout_error.py','gateway_test.py','data.npz'):
            self.assertNotIn(noise,out)
        self.assertIn('=== Tokenizer/vocabulary assets ===',out)
        self.assertIn('ggml-vocab-gemma.gguf',out)
        self.assertIn('gateway.py',out)

    def test_backend_files_are_grouped_by_installation(self):
        for version in ('runtime-1','runtime-2'):
            folder=self.store/'extensions/backends'/version;folder.mkdir(parents=True)
            for name in ('ggml-cuda.dll','ggml-cpu.dll','ggml-base.dll','cublas64.dll'):(folder/name).write_bytes(b'x'*4096)
        out=self.run_audit()
        section=out.split('=== Backend/runtime installations ===',1)[1].split('=== Tokenizer/vocabulary assets ===',1)[0]
        self.assertEqual(section.count('  Installation:'),2,out)
        self.assertEqual(section.count('4 files;'),2,out)
        self.assertIn('CUDA',section)
        self.assertIn('GGML/CPU',section)

    def test_explicit_gateway_root_keeps_custom_entrypoint(self):
        folder=self.store/'custom-server';folder.mkdir();(folder/'proxy.py').write_text('raise RuntimeError("never execute")')
        if os.name=='nt':extra='-GatewayRoot "'+str(folder)+'"'
        else:extra='--gateway-root '+str(folder)
        self.assertIn('proxy.py',self.run_audit(extra))

    @unittest.skipIf(os.name=='nt','Unix filename fallback')
    def test_no_python_filename_fallback(self):
        binpath=self.base/'bin';binpath.mkdir()
        for name in ('bash','uname','du','awk','sort','find','df','stat'):
            target=shutil.which(name)
            if target:(binpath/name).symlink_to(target)
        (self.store/'mmproj-F16.gguf').write_bytes(b'fixture')
        for n in (1,3):gguf(self.store/('split-%05d-of-00003.gguf'%n),{})
        self.env['PATH']=str(binpath)
        out=self.run_audit()
        self.assertIn('multimodal projector candidate [filename]',out)
        self.assertIn('Shards: 2/3 present; missing: 00002',out)
        self.assertEqual(out.count('  Model set:'),1,out)

    @unittest.skipUnless(os.name=='nt','Windows provider fallback')
    def test_no_compiler_groups_shards(self):
        for n in (1,2):gguf(self.store/('split-%05d-of-00002.gguf'%n),{})
        out=self.run_audit(prefix="function Add-Type { throw 'fixture compiler unavailable' }; ")
        self.assertIn('Shards: 2/2 present',out)
        self.assertEqual(out.count('  Model set:'),1,out)

if __name__=='__main__':unittest.main()
