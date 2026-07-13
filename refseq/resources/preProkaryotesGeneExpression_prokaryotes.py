"""历史研究脚本，不是当前 RefSeq 下载或数据库构建入口。

该文件保留早期原核转录组预处理实验流程、工具路径和数据路径，仅供追溯。
它没有稳定命令行接口，不应直接用于当前 RefSeq 数据库。
"""

import sys

if __name__ == '__main__':
    raise SystemExit("历史研究脚本没有受支持的命令行入口；当前 RefSeq 下载请使用 genomes_dir/download_refseq_genomes_api.sh。")

import os
import os.path as osp
import pandas as pd
import numpy as np
import time
import glob
import csv
import re
import shutil
import pdb
import transformers
MAX_INT=sys.maxsize

from Bio import SeqIO
from Bio.Seq import Seq

root_path = '/data/p25wuhx/projects/GetGeneExpression/preprocess/fromlist/prokaryotes/'
save_path = '/data/p25wuhx/bert_prism/datasets/expressions/fromlist/prokaryotes/'


def getAccessions():
    df = pd.read_excel(osp.join(root_path, 'accessions602.xlsx'), engine='openpyxl', header=None)
    idlist = df.iloc[:,-1].tolist()
    for i in range(len(idlist)):
        idlist[i] = idlist[i].replace('\t', '').replace(' ', '')
    df.iloc[:,-1] = idlist
    # df = df[df.iloc[:,-1] != 'SRR8573812'].reset_index(drop=True)  # too big, > 5GB——原因，下载太慢
    df.to_csv(osp.join(root_path, 'accessions602.csv'), sep=',', index=False, header=False)
    
    data = np.array(idlist)
    np.savetxt(osp.join(root_path, 'idList.txt'), data, fmt='%s', delimiter=',')
    
def prefetch():
    idList = pd.read_csv(osp.join(root_path, 'idList.txt'), header=None)

    if not osp.exists(osp.join(save_path, 'prefetchs')):
        os.makedirs(osp.join(save_path, 'prefetchs'))

    # idList_downloaded = os.listdir(osp.join(save_path, 'prefetchs'))
    # idList_left = []
    # for access in idList[0].tolist():
    #     if not access in idList_downloaded:
    #         idList_left.append(access)
    # pdb.set_trace()
    
    # idList = pd.DataFrame(['SRR5445357', 'SRR5307610', 'SRR27163915', 'SRR10675096', 'SRR12149730'])
    # idList = pd.DataFrame(['SRR5307610', 'SRR12149730'])
    
    # ascp_path = '"/home/whx/.aspera/connect/bin/ascp|/home/whx/.aspera/connect/etc/asperaweb_id_dsa.openssh"'
    
    for i in range(len(idList)):
        start = time.time()
        accession = idList[0][i]
        
        # cmd_download = 'prefetch --ascp-path {} {} -O {}'.format(ascp_path, accession, osp.join(save_path, 'prefetchs/'))
        cmd_download = 'prefetch {} -O {} &'.format(accession, osp.join(save_path, 'prefetchs/'))
        res_download = os.system(cmd_download)
        print('Time: {}s'.format(time.time()-start), res_download, flush=True)
    
    # prefetch --ascp-path "/home/whx/.aspera/connect/bin/ascp|/home/whx/.aspera/connect/etc/asperaweb_id_dsa.openssh" SRR24304171 -O /hy-tmp/expressions/fromlist/prokaryotes/prefetchs/
    
    # ascp_path = '"/home/whx/.aspera/connect/bin/ascp|/home/whx/.aspera/connect/etc/asperaweb_id_dsa.openssh"'
    # option_file = "/hy-tmp/expressions/manual/idList.txt"
    # cmd_download = 'prefetch --ascp-path {} --option-file {} -O {}'.format(ascp_path, option_file, osp.join(save_path, 'prefetchs/'))
    # os.system(cmd_download)
    # print('Done.')
    
def split10folders():
    idList = pd.read_csv(osp.join(root_path, 'idList.txt'), header=None)
    idList = idList[0].tolist()
    
    foldernamelist = [
        'prefetchs_split1',
        'prefetchs_split2',
        'prefetchs_split3',
        'prefetchs_split4',
        'prefetchs_split5',
        'prefetchs_split6',
        'prefetchs_split7',
        'prefetchs_split8',
        'prefetchs_split9',
        'prefetchs_split10',
    ]
    for foldername in foldernamelist:
        if not osp.exists(osp.join(save_path, foldername)):
            os.makedirs(osp.join(save_path, foldername))

    for i in range(len(idList)):
        if not osp.exists(osp.join(save_path, 'prefetchs', idList[i])):
            print(str(i+1), idList[i], 'not exit. Error.')
            continue
        
        if i < 60:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split1'))
        elif i >= 60 and i < 120:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split2'))
        elif i >= 120 and i < 180:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split3'))
        elif i >= 180 and i < 240:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split4'))
        elif i >= 240 and i < 300:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split5'))
        elif i >= 300 and i < 360:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split6'))
        elif i >= 360 and i < 420:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split7'))
        elif i >= 420 and i < 480:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split8'))
        elif i >= 480 and i < 540:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split9'))
        elif i >= 540:
            cmd = 'mv {} {}'.format(osp.join(save_path, 'prefetchs', idList[i]), osp.join(save_path, 'prefetchs_split10'))
            
        res = os.system(cmd)
        print(str(i+1), idList[i], 'done.', res, flush=True)

def fasterq_dump():
    ###############################################
    # 当prefetch数据太大时，在/hy-tmp目录下运行此函数
    ###############################################
    k = -1  # [1, 10]
    
    idList = pd.read_csv(osp.join(root_path, 'idList.txt'), header=None)
    idList = idList[0].tolist()
    
    # if not osp.exists(osp.join(save_path, 'fasterq_dumps')):
    #     os.makedirs(osp.join(save_path, 'fasterq_dumps'))
    
    prefetch_f = 'prefetchs_split' + str(k)
    fasterq_dump_f = 'fasterq_dumps_split' + str(k)
    
    # idList = ['SRR24304171'] - 1
    # idList = ['ERR3316576'] - 8
    # for i in range(len(idList)):
    start_i, end_i = (k-1)*60, k*60
    if k == 10:
        end_i = 602
    if k == -1:
        start_i = 0
        end_i = len(idList)
    for i in range(start_i, end_i):
        start = time.time()
        accession = idList[i].replace('\n', '').split(',')[-1]
        # pdb.set_trace()
        cmd_download = 'fasterq-dump {} -O {} -e {}'.format(osp.join(save_path, prefetch_f, accession), osp.join(save_path, fasterq_dump_f, accession), 32)
        res_download = os.system(cmd_download)
        print('Time: {}s'.format(time.time()-start), res_download)
        print(str(i+1) + ',' + accession)
        print(flush=True)
        
    # fasterq-dump /hy-tmp/expressions/fromlist/prokaryotes/prefetchs_split1/SRR24304171 -O /hy-tmp/expressions/fromlist/prokaryotes/fasterq_dumps_split1/SRR24304171 -e 32

def get_FNA_GTF_Folders():
    ############################
    # GCA_002240375.1 -> GCA_002240375.2
    ############################
    
    # 加载原核生物列表
    prokaryotes = {}
    f = open('/home/whx/projects/GetGeneExpression/preprocess/fromlist/genomes_filtered.csv')
    file = f.readlines()
    for line in file:
        line_cut = line.replace('\n', '').split(',')[1:]
        prokaryotes[line_cut[0]] = line_cut
    f.close()
    
    accessions = []
    f = open(osp.join(root_path, 'accessions602.csv'))
    file = f.readlines()
    for line in file:
        line_cut = line.replace('\n', '').split(',')[1:]
        accessions.append(line_cut)
    f.close()
    
    # accessions = accessions[:60]
    # pdb.set_trace()
    
    download_path = '/hy-tmp/expressions/fromlist/prokaryotes/datasetsZipped'
    unzipped_path = '/hy-tmp/expressions/fromlist/prokaryotes/datasetsUnzipped'
    # unzipped_path = '/root/projects/GetGeneExpression/data/'
    if not os.path.exists(download_path):
        os.mkdir(download_path)
    if not os.path.exists(unzipped_path):
        os.mkdir(unzipped_path)
    
    # accessions = [
    #     ['T00282', 'pha', '326442', 'Pseudoalteromonas translucida TAC125', '24699379', 'SRR21786405'],
    #     # ['T06081', 'lwl', '28184', 'Leptospira weilii', '28596444', 'SRR25426524']
    # ]
    for i in range(len(accessions)):
        print('#################################################')
        print(str(i+1), accessions[i][0], prokaryotes[accessions[i][0]][2], prokaryotes[accessions[i][0]][-2])
        print('#################################################')
        
        # if not accessions[i][1] == prokaryotes[accessions[i][1]][2]:
        #     print('tax_id mismatch.')
        #     continue
        
        # taxon / accession
        fna_download = os.path.join(download_path, accessions[i][0] + '_fna')
        # cmd_download = 'datasets download genome taxon {} --dehydrated --filename {}.zip'.format(prokaryotes[accessions[i][0]][2], fna_download)
        cmd_download = 'datasets download genome accession {} --dehydrated --filename {}.zip'.format(prokaryotes[accessions[i][0]][-2], fna_download)
        res_download = os.system(cmd_download)
        print(res_download)
        # pdb.set_trace()
        filename_unzipped = os.path.join(unzipped_path, accessions[i][0] + '_fna')
        cmd_unzip = 'unzip {}.zip -d {}'.format(fna_download, filename_unzipped)
        res_unzip = os.system(cmd_unzip)
        print(res_unzip)
        
        gtf_download = os.path.join(download_path, accessions[i][0] + '_gtf')
        # cmd_download = 'datasets download genome taxon {} --dehydrated --include gtf --filename {}.zip'.format(prokaryotes[accessions[i][0]][2], gtf_download)
        cmd_download = 'datasets download genome accession {} --dehydrated --include gtf --filename {}.zip'.format(prokaryotes[accessions[i][0]][-2], gtf_download)
        res_download = os.system(cmd_download)
        print(res_download)
        
        filename_unzipped = os.path.join(unzipped_path, accessions[i][0] + '_gtf')
        cmd_unzip = 'unzip {}.zip -d {}'.format(gtf_download, filename_unzipped)
        res_unzip = os.system(cmd_unzip)
        print(res_unzip)
        # pdb.set_trace()
        print()

def select_FNA_GTF_Links():
    ############################
    # GCA_002240375.1 -> GCA_002240375.2
    ############################
    
    genome_filtered = pd.read_csv('/home/whx/projects/GetGeneExpression/preprocess/fromlist/genomes_filtered.csv', header=None)
    
    handle = open(osp.join(root_path, 'accessions602.csv'))
    file = handle.readlines()
    handle.close()
    accessions = []
    for line in file:
        line_cut = line.replace('\n', '').split(',')[1:]
        if line_cut[0] in genome_filtered[1].tolist():
            filename = genome_filtered[genome_filtered[1]==line_cut[0]]
        else:
            print(line_cut[0], 'not in genome_filtered.csv')
            # exit()
        line_cut.append(filename[6].item())
        accessions.append(line_cut)

    # 汇总links
    unzipped_path = '/hy-tmp/expressions/fromlist/prokaryotes/datasetsUnzipped'
    # folder_lists = os.listdir(unzipped_path)
    
    links = []
    for i in range(len(accessions)):
        filename_unzipped_fna = os.path.join(unzipped_path, accessions[i][0]+'_fna', 'ncbi_dataset/fetch.txt')
        filename_unzipped_gtf = os.path.join(unzipped_path, accessions[i][0]+'_gtf', 'ncbi_dataset/fetch.txt')
        if not os.path.exists(filename_unzipped_fna):
            print(accessions[i][0]+'_fna', 'has no fetch.txt. Skip.')
            continue
        if not os.path.exists(filename_unzipped_gtf):
            print(accessions[i][0]+'_gtf', 'has no fetch.txt. Skip.')
            continue

        find_link = False
        f = open(filename_unzipped_fna, 'r')
        file_fna = f.readlines()
        f.close()
        for line in file_fna:
            if accessions[i][-1] == 'GCA_002240375.1':
                accessions[i][-1] = 'GCA_002240375.2'
            
            if accessions[i][-1] in line:
                find_link = True
                line_cut = line.replace('\n', '').split('\t')
                line_cat = line_cut[0] + '\t' + line_cut[1] + '\t' + '../datasetsDownloaded/' + accessions[i][0] + '/' + line_cut[-1].split('/')[-1]
                links.append(line_cat)
        if not find_link:
            print(accessions[i][0], "can't find the specific link.")

        find_link = False
        f = open(filename_unzipped_gtf, 'r')
        file_gtf = f.readlines()
        f.close()
        for line in file_gtf:
            if accessions[i][-1] in line:
                find_link = True
                line_cut = line.replace('\n', '').split('\t')
                line_cat = line_cut[0] + '\t' + line_cut[1] + '\t' + '../datasetsDownloaded/' + accessions[i][0] + '/' + line_cut[-1].split('/')[-1]
                links.append(line_cat)
        if not find_link:
            print(accessions[i][0], "can't find the specific link.")

    fetch_path = '/hy-tmp/expressions/fromlist/prokaryotes/ncbi_dataset'
    if not os.path.exists(fetch_path):
        os.mkdir(fetch_path)
    
    data = np.asarray(links)
    np.savetxt(os.path.join(fetch_path, 'fetch.txt'), data, fmt='%s')

def fetch_FNS_GTF_datasets():
    prokaryotes_path = '/hy-tmp/expressions/fromlist/prokaryotes/'
    if not os.path.exists(os.path.join(prokaryotes_path, 'datasetsDownloaded')):
        os.mkdir(os.path.join(prokaryotes_path, 'datasetsDownloaded'))
    # cmd_fetch = 'datasets rehydrate --directory {} --max-workers 30'.format(prokaryotes_path)
    cmd_fetch = 'datasets rehydrate --directory {}'.format(prokaryotes_path)
    res_fetch = os.system(cmd_fetch)


##### get tpm+gene #####
import subprocess
def run_command(command):
    result = subprocess.run(command, shell=True)
    if result.returncode != 0:
        raise Exception(f"Command failed: {command}")

def getCounts():
    k = -1
    
    accessions = []
    f = open(osp.join(root_path, 'accessions602.csv'))
    file = f.readlines()
    for line in file:
        line_cut = line.replace('\n', '').split(',')[1:]
        accessions.append(line_cut)
    f.close()
    
    output_dir = osp.join(save_path, 'output_split'+str(k))
    tmp_dir = osp.join(save_path, 'tmp')
    if not os.path.exists(output_dir):
        os.mkdir(output_dir)
    if not os.path.exists(tmp_dir):
        os.mkdir(tmp_dir)
    
    # tmp_taxon = ['T05116']  # 1 - SRR24304171
    tmp_taxon = []  # 2,3,4,5,6,7,9,10 - None
    # tmp_taxon = ['T07087']  # 8 - ERR3316576
    
    # for i in range(len(accessions)):
    start_i, end_i = (k-1)*60, k*60
    if k == 10:
        start_i = 600
        end_i = 602
    for i in range(start_i, end_i):
        taxon = accessions[i][0]
        sra_id = accessions[i][-1]
        
        if taxon in tmp_taxon:
            print(taxon, 'skip.')
            continue
        # if not taxon in tmp_taxon:
        #     continue
        
        fastq_path = osp.join(save_path, 'fasterq_dumps_split'+str(k), sra_id)
        reference_genome = glob.glob(osp.join(save_path, 'datasetsDownloaded', taxon, '*.fna'))[0]
        gtf_file = osp.join(save_path, 'datasetsDownloaded', taxon, 'genomic.gtf')
                
        if len(os.listdir(fastq_path)) == 1 :
            # 单端测序            
            run_command(f"/root/projects/GetGeneExpression/tools/bowtie2-2.5.4-linux-x86_64/bowtie2-build {reference_genome} {reference_genome[:-4]}")
            run_command(f"/root/projects/GetGeneExpression/tools/bowtie2-2.5.4-linux-x86_64/bowtie2 -p 32 -U {fastq_path}/{sra_id}.fastq -x {reference_genome[:-4]} | samtools view -@ 32 -bS -u - | samtools sort -@ 32 -o {tmp_dir}/aligned_reads.sorted.bam -")
    
            # run_command(f"bwa index {reference_genome}")
            # run_command(f"bwa mem {reference_genome} {fastq_path}/{sra_id}.fastq > {tmp_dir}/aligned_reads.sam")
            # run_command(f"samtools view -Sb {tmp_dir}/aligned_reads.sam > {tmp_dir}/aligned_reads.bam")
            # run_command(f"samtools sort {tmp_dir}/aligned_reads.bam -o {tmp_dir}/aligned_reads.sorted.bam")
            run_command(f"samtools index {tmp_dir}/aligned_reads.sorted.bam")
            # run_command(f"htseq-count -f bam -r pos -s yes -t gene -i gene_id -m union {tmp_dir}/aligned_reads.sorted.bam {gtf_file} > {output_dir}/{sra_id}.txt")
            run_command(f"featureCounts -T 32 -Q 10 -O -a {gtf_file} -o {output_dir}/{sra_id}_featureCounts.txt -t gene -g gene_id {tmp_dir}/aligned_reads.sorted.bam")
        else:
            # 双末端测序
            run_command(f"/root/projects/GetGeneExpression/tools/bowtie2-2.5.4-linux-x86_64/bowtie2-build {reference_genome} {reference_genome[:-4]}")
            run_command(f"/root/projects/GetGeneExpression/tools/bowtie2-2.5.4-linux-x86_64/bowtie2 -p 32 -1 {fastq_path}/{sra_id}_1.fastq -2 {fastq_path}/{sra_id}_2.fastq -x {reference_genome[:-4]} | samtools view -@ 32 -bS -u - | samtools sort -@ 32 -o {tmp_dir}/aligned_reads.sorted.bam -")
            
            # run_command(f"bwa index {reference_genome}")
            # run_command(f"bwa mem {reference_genome} {fastq_path}/{sra_id}_1.fastq {fastq_path}/{sra_id}_2.fastq > {tmp_dir}/aligned_reads.sam")
            # run_command(f"samtools view -Sb {tmp_dir}/aligned_reads.sam > {tmp_dir}/aligned_reads.bam")
            # run_command(f"samtools sort {tmp_dir}/aligned_reads.bam -o {tmp_dir}/aligned_reads.sorted.bam")
            run_command(f"samtools index {tmp_dir}/aligned_reads.sorted.bam")
            # run_command(f"htseq-count -f bam -r pos -s reverse -t gene -i gene_id -m union {tmp_dir}/aligned_reads.sorted.bam {gtf_file} > {output_dir}/{sra_id}.txt")
            run_command(f"featureCounts -T 32 -Q 10 -O -a {gtf_file} -o {output_dir}/{sra_id}_featureCounts.txt -p -B -C -t gene -g gene_id {tmp_dir}/aligned_reads.sorted.bam")
        # 保留比对中间产物，避免历史流程清理时直接丢失文件。
        trash_dir = osp.join(save_path, 'trash', 'alignment_tmp', f'{sra_id}_{time.time_ns()}')
        os.makedirs(trash_dir, exist_ok=True)
        for tmp_name in os.listdir(tmp_dir):
            shutil.move(osp.join(tmp_dir, tmp_name), osp.join(trash_dir, tmp_name))
        print(str(i+1), taxon, sra_id, 'done.', flush=True)

def getTPMs():
    accessions = []
    f = open(osp.join(root_path, 'accessions602.csv'))
    file = f.readlines()
    for line in file:
        line_cut = line.replace('\n', '').split(',')[1:]
        accessions.append(line_cut)
    f.close()
    
    tpm_dir = osp.join(save_path, 'tpm')
    if not os.path.exists(tpm_dir):
        os.mkdir(tpm_dir)
        
    # tmp_taxon = ['T05116', 'T07087']
    tmp_taxon = [
        'T05116', 'T07087',                       # error
        'T02448', 'T01197', 'T04851', 'T02497'    # short genome
    ]
    for i in range(len(accessions)):
        taxon = accessions[i][0]
        # accession = accessions[i][6]
        
        if taxon in tmp_taxon:
            print(taxon, 'skip.', flush=True)
            continue
        
        handle = open(osp.join(save_path, 'featureCounts', accessions[i][-1]+'_featureCounts.txt'))
        counts_file = handle.readlines()
        handle.close()
        
        newlines = []
        counts = 0
        # for line in counts_file[:-5]:
        #     line_cut = line.replace('\n', '').split('\t')
        #     line_cut[-1] = int(line_cut[-1])
        #     counts += line_cut[-1]
        #     newlines.append(line_cut)
        for line in counts_file[2:]:
            line_cut = line.replace('\n', '').split('\t')
            line_cut[-1] = int(line_cut[-1])
            counts += line_cut[-1]
            newlines.append([line_cut[0], line_cut[-1]])
        
        # if counts <= 0:
        #     print(taxon, 'error! count==0.', flush=True)
        #     continue
        
        for j in range(len(newlines)):
            if counts <= 0:
                tpm = 0
            else:
                tpm = newlines[j][-1] / counts * 1e+6
            newlines[j].append(tpm)
        
        df = pd.DataFrame(newlines, columns=['GeneId', 'Count', 'TPM'])
        df.to_csv(osp.join(tpm_dir, accessions[i][-1]+'.csv'), sep=',', index=False)
    print('Done.')

def cutGeneFromGTFs():
    accessions = []
    f = open(osp.join(root_path, 'accessions602.csv'))
    file = f.readlines()
    for line in file:
        line_cut = line.replace('\n', '').split(',')[1:]
        accessions.append(line_cut)
    f.close()
    
    genes_path = osp.join(save_path, 'genes')
    if not os.path.exists(genes_path):
        os.mkdir(genes_path)
    
    # tmp_taxon = ['T05116', 'T07087']
    tmp_taxon = [
        'T05116', 'T07087',                       # error
        'T02448', 'T01197', 'T04851', 'T02497'    # short genome
    ]
    starttime = time.time()
    for i in range(len(accessions)):
        taxon = accessions[i][0]
        short_name = accessions[i][1]
        # accession = accessions[i][6]
        
        if taxon in tmp_taxon:
            print(taxon, 'skip.', flush=True)
            continue
        
        reference_genome = glob.glob(osp.join(save_path, 'datasetsDownloaded', accessions[i][0], '*.fna'))[0]
        genomelist = [fa.seq for fa in SeqIO.parse(reference_genome,  "fasta")]
        if len(genomelist) == 1:
            genome = genomelist[0]
        else:
            genome = Seq('')
            for g in genomelist:
                genome += g
        
        handle = open(osp.join(save_path, 'featureCounts', accessions[i][-1]+'_featureCounts.txt'))
        counts_file = handle.readlines()
        handle.close()

        newlines = []
        counts = 0
        column = counts_file[1].replace('\n', '').split('\t')
        column[-1] = 'Count'
        for line in counts_file[2:]:
            line_cut = line.replace('\n', '').split('\t')
            line_cut[-1] = int(line_cut[-1])
            counts += line_cut[-1]
            newlines.append(line_cut)
        df = pd.DataFrame(newlines, columns=column)
        
        gene_path = osp.join(genes_path, accessions[i][0]+'_'+accessions[i][-1]+'.txt')
        f2 = open(gene_path, 'w')
        
        df_filtered = pd.DataFrame()
        for j in range(len(df)):
            flag_join = ' '
            flag_complement = ' '
            gene_id = df.iloc[j]['Geneid']
            startSeq = df.iloc[j]['Start']
            endSeq = df.iloc[j]['End']
            strand = df.iloc[j]['Strand']
            
            if not ';' in startSeq:   # 非拼接
                if strand == '+':  # 正链
                    startSeq = int(startSeq)
                    endSeq = int(endSeq)
                    startPromoter = startSeq - 200
                    if startPromoter < 1:
                        # startPromoter = 1
                        continue
                    gene = genome[startSeq-1:endSeq]
                    promoter = genome[startPromoter-1:startSeq-1]
                else:  # 反链
                    flag_complement = 'complement'
                    startSeq = int(startSeq)
                    endSeq = int(endSeq)
                    endPromoter = endSeq + 200
                    if endPromoter > len(genome):
                        # endPromoter = len(genome) - 1
                        continue
                    gene = genome[startSeq-1:endSeq].complement()[::-1]
                    promoter = genome[endSeq:endPromoter].complement()[::-1]
            else:  # 拼接
                flag_join = 'joined'   # gene是拼接的
                numOfSlice = len(strand.split(';'))
                strand = strand[0]
                start = startSeq.split(';')
                end = endSeq.split(';')
                # startSeq = min([int(num) for num in startSeq.split(';')])
                # endSeq = max([int(num) for num in endSeq.split(';')])
                
                if strand == '+':  # 正链
                    min_pos = MAX_INT
                    gene = Seq('')
                    for k in range(numOfSlice):
                        startSeq = int(start[k])
                        endSeq = int(end[k])
                        min_pos = min(startSeq, min_pos)
                        gene += genome[startSeq-1:endSeq]
                    startPromoter = min_pos - 200
                    if startPromoter < 1:
                        # startPromoter = 1
                        continue
                    promoter = genome[startPromoter-1:min_pos-1]
                    
                    # startSeq = int(startSeq)
                    # endSeq = int(endSeq)
                    # startPromoter = startSeq - 200
                    # if startPromoter < 1:
                    #     startPromoter = 1
                    # gene = genome[startSeq-1:endSeq]
                    # promoter = genome[startPromoter-1:startSeq-1]
                else:  # 反链
                    flag_complement = 'complement'
                    max_pos = 0
                    gene = Seq('')
                    for k in range(numOfSlice):
                        startSeq = int(start[k])
                        endSeq = int(end[k])
                        max_pos = max(endSeq, max_pos)
                        gene += genome[startSeq-1:endSeq]
                    gene = gene.complement()[::-1]
                    endPromoter = max_pos + 200
                    if endPromoter >= len(genome):
                        # endPromoter = len(genome) - 1
                        continue
                    promoter = genome[max_pos:endPromoter]
                    promoter = promoter.complement()[::-1]
                    
                    # flag_complement = 'complement'
                    # startSeq = int(startSeq)
                    # endSeq = int(endSeq)
                    # endPromoter = endSeq + 200
                    # if endPromoter >= len(genome):
                    #     endPromoter = len(genome) - 1
                    # gene = genome[startSeq-1:endSeq].complement()[::-1]
                    # promoter = genome[endSeq:endPromoter].complement()[::-1]

            if not len(promoter) == (promoter.count('A') + promoter.count('T') + promoter.count('G') + promoter.count('C')):
                # print('Unknown base in promoter.')
                continue
            if not len(gene) == (gene.count('A') + gene.count('T') + gene.count('G') + gene.count('C')):
                # print('Unknown base in gene.')
                continue
            # if not len(gene) == int(df.iloc[j]['Length']):
            #     pdb.set_trace()
            #     print('Error3.')
            if gene == '':
                print('Error. Gene is ''.', flush=True)
                # pdb.set_trace()
                continue
            if promoter == '':
                print("Error. Promoter is ''.", flush=True)
                # pdb.set_trace()
                continue
                
            df_filtered = pd.concat([df_filtered, df.iloc[j:j+1]])
            newline = short_name+':'+gene_id + ',' + str(promoter) + ',' + str(gene) + ',' + flag_complement + ',' + flag_join + '\n'
            f2.write(newline)
        # df_filtered.to_csv(osp.join(), sep=",", index=False, header=False)
        print('No:{}  ID:{}  Name:{} writed.  Length:{}  Actually length:{}, minus:{}'.format(str(i), accessions[i][0], accessions[i][-1], len(df), len(df_filtered), len(df)-len(df_filtered)), flush=True)
        f2.close()
        
    print(time.time()-starttime, 's.') 
    print('Done.')

def getGeneTPMs():
    accessions = []
    f = open(osp.join(root_path, 'accessions602.csv'))
    file = f.readlines()
    for line in file:
        line_cut = line.replace('\n', '').split(',')[1:]
        accessions.append(line_cut)
    f.close()
    
    f = open('/root/projects/GetGeneExpression/preprocess/fromlist/ecos/data/genomes_filtered.csv', 'r')
    lines = f.readlines()
    ProkaryotesClassificationList = {}
    for line in lines:
        line_cut = line.replace('\n', '').split(',')[1:]
        ProkaryotesClassificationList[line_cut[0]] = line_cut
    f.close()
    
    tpm_gene_dir = osp.join(save_path, 'tpm_gene')
    if not os.path.exists(tpm_gene_dir):
        os.mkdir(tpm_gene_dir)
    
    tmp_taxon = [
        'T05116', 'T07087',                       # error
        'T02448', 'T01197', 'T04851', 'T02497'    # short genome
    ]
    newlines = []
    for i in range(len(accessions)):
        taxon = accessions[i][0]
        accession = accessions[i][-1]
        
        if taxon in tmp_taxon:
            print(i+1, taxon, 'skip.', flush=True)
            continue
        
        short_name = ProkaryotesClassificationList[taxon][1]
        
        gene_filename = osp.join(save_path, 'genes', taxon+'_'+accession+'.txt')
        f = open(gene_filename)
        genes_file = f.readlines()
        genes_dict = {}
        for line in genes_file:
            line_cut = line.replace('\n', '').split(',')
            genes_dict[line_cut[0]] = line_cut
        f.close()
        
        tpm_gene = open(osp.join(save_path, 'tpm_gene', taxon+'_'+accession+'_tpm_gene.txt'), 'w')
        tpm_gene.write('geneId,promoter,gene,tpm\n')
        
        tpm_file = pd.read_csv(osp.join(save_path, 'tpm/', accession+'.csv'))
        for j in range(len(tpm_file)):
            geneId = short_name + ':' + tpm_file.iloc[j]['GeneId']
            tpm = tpm_file.iloc[j]['TPM']
            if not geneId in genes_dict.keys():
                continue
            else:
                promoter = genes_dict[geneId][1]
                gene = genes_dict[geneId][2]
            # newlines.append([geneId, promoter, gene, tpm])
            newline = geneId + ',' + promoter + ',' + gene + ',' + str(tpm) + '\n'
            tpm_gene.write(newline)
        tpm_gene.close()
        # pdb.set_trace()
        # df = pd.DataFrame(newlines, columns=['geneId', 'promoter', 'gene', 'tpm'])
        # df.to_csv(osp.join(save_path, 'tpm_gene', accession+'.csv'), sep=',', index=False)
        print(i+1, taxon, accession, 'done.', flush=True)
    # pdb.set_trace()

def tpm_gene_txt():
    namelist = os.listdir(osp.join(save_path, 'tpm_gene'))
    
    tpm_gene = open(osp.join(save_path, 'data/tpm_gene_prokaryotes.txt'), 'w')
    tpm_gene.write('geneId,promoter,gene,tpm\n')
    for i in range(len(namelist)):
        handle = open(osp.join(save_path, 'tpm_gene', namelist[i]), 'r')
        lines = handle.readlines()
        handle.close()
        
        tpm_gene.writelines(lines[1:])
    tpm_gene.close()

def getTokens_prokaryotes():
    # gene = 'atggtgagcaagggcgaggagctgttcaccggggtggtgcccatcctggtcgagctggacggcgacgtaaacggccacaagttcagcgtgtccggcgagggcgagggcgatgccacctacggcaagctgaccctgaagttcatctgcaccaccggcaagctgcccgtgccctggcccaccctcgtgaccaccctgacctacggcgtgcagtgcttcagccgctaccccgaccacatgaagcagcacgacttcttcaagtccgccatgcccgaaggctacgtccaggagcgcaccatcttcttcaaggacgacggcaactacaagacccgcgccgaggtgaagttcgagggcgacaccctggtgaaccgcatcgagctgaagggcatcgacttcaaggaggacggcaacatcctggggcacaagctggagtacaactacaacagccacaacgtctatatcatggccgacaagcagaagaacggcatcaaggtgaacttcaagatccgccacaacatcgaggacggcagcgtgcagctcgccgaccactaccagcagaacacccccatcggcgacggccccgtgctgctgcccgacaaccactacctgagcacccagtccgccctgagcaaagaccccaacgagaagcgcgatcacatggtcctgctggagttcgtgaccgccgccgggatcactctcggcatggacgagctgtacaagtaa'

    model_name_or_path = '/hy-tmp/ckpt/checkpoint-720000_newtoken/'
    
    model_max_length = 100
    data_path = osp.join(save_path, 'tpm_gene/')
    token_path = osp.join(save_path, 'tpm_gene_npz/')
    
    if not osp.exists(token_path):
        os.mkdir(token_path)
        
    tokenizer = transformers.AutoTokenizer.from_pretrained(
        model_name_or_path,
        # cache_dir=training_args.cache_dir,
        model_max_length=model_max_length,
        padding_side="right",
        use_fast=True,
        trust_remote_code=True,
    )

    start = time.time()
    accessions = pd.read_csv(osp.join(root_path, 'accessions602.csv'), sep=',', header=None)
    count = 0
    
    tmp_taxon = ['T05116', 'T02448', 'T01197', 'T04851', 'T02497', 'T07087']
    for i in range(len(accessions)):
        taxon = accessions.iloc[i][1]
        accession = accessions.iloc[i][6]
        
        if taxon in tmp_taxon:
            print(taxon, 'skip.', flush=True)
            continue
        
        file_path = taxon + '_' + accession + '_tpm_gene.txt'
        gene_path = osp.join(data_path, file_path)
        
        f = open(gene_path)
        file = f.readlines()
        f.close()

        sequences = []
        intensity = []
        for line in file[1:]:
            line = line.replace('\n', '').split(',')
            seq = line[1] + line[2]
            # seq = line[1] + gene.upper()
            sequences.append(seq)
            intensity.append(float(line[3]))
        
        output = tokenizer(
            sequences, 
            return_tensors="np", 
            padding="max_length", 
            max_length=tokenizer.model_max_length, 
            truncation=True
        )
        data = output['input_ids']
        masks = output['attention_mask']
        intensity = np.array(intensity)
        
        if not len(data) == len(sequences):
            print('Error 1.', flush=True)
            pdb.set_trace()
        if not len(data) == len(intensity):
            print('Error 2.', flush=True)
            pdb.set_trace()
        
        count += len(data)
        
        np.savez_compressed(os.path.join(token_path, taxon+'_'+accession+'_newtoken.npz'), **{'sequences':data, 'masks': masks, 'intensity': intensity})
        # np.save(os.path.join(token_path, taxon+'_'+accession+'_tpm_gene.npy'), data)
    
        print(str(i+1), 'saved.', len(data), flush=True)
        # pdb.set_trace()
    print("Token saving time: ", time.time()-start, 's.', "Count: ", count)

def tpm_gene_npz():
    data_path = osp.join(save_path, 'tpm_gene_npz/')    
    namelist = os.listdir(data_path)
    
    accessions = pd.read_csv(osp.join(root_path, 'accessions602.csv'), sep=',', header=None)
    
    tmp_taxon = ['T05116', 'T02448', 'T01197', 'T04851', 'T02497', 'T07087']
    sequences_all = np.array([[0 for _ in range(100)]])
    masks_all = np.array([[0 for _ in range(100)]])
    intensity_all = np.array([0])
    
    for i in range(len(accessions)):
        taxon = accessions.iloc[i][1]
        accession = accessions.iloc[i][6]
        
        if taxon in tmp_taxon:
            print(i+1, taxon, 'skip.', flush=True)
            continue
        
        file_path = taxon + '_' + accession + '_newtoken.npz'
        gene_path = osp.join(data_path, file_path)
        file = np.load(gene_path)
        sequences = file['sequences']
        masks = file['masks']
        intensity = file['intensity']
        
        sequences_all = np.concatenate([sequences_all, sequences], axis=0)
        masks_all = np.concatenate([masks_all, masks], axis=0)
        intensity_all = np.concatenate([intensity_all, intensity], axis=0)
        print(i+1, taxon, 'done.', flush=True)
    sequences_all = sequences_all[1:]
    masks_all = masks_all[1:]
    intensity_all = intensity_all[1:]
    np.savez_compressed(os.path.join(save_path, 'data/tpm_gene_prokaryotes_newtoken.npz'), **{'sequences':sequences_all, 'masks': masks_all, 'intensity': intensity_all})


##### get tss #####
def parse_gtf(gtf_file):
    columns = ['seqname', 'source', 'feature', 'start', 'end', 'score', 'strand', 'frame', 'attribute']
    gtf = pd.read_csv(gtf_file, sep='\t', comment='#', names=columns)

    # Filter for gene features
    genes = gtf[gtf['feature'] == 'gene'].copy()
    left_lines = gtf[gtf['feature'] != 'gene'].copy()
    
    # Parse attributes into a dictionary
    def parse_attributes(attribute_string):
        attributes = {}
        for attribute in attribute_string.split('; '):
            if attribute.strip():
                try:
                    key, value = attribute.strip().split(' "')
                except:
                    continue
                    # pdb.set_trace()
                attributes[key] = value.strip('"')
        return attributes

    genes.loc[:, 'attributes'] = genes['attribute'].apply(parse_attributes)
    left_lines.loc[:, 'attributes'] = left_lines['attribute'].apply(parse_attributes)
    left_lines.loc[:, 'gene_id'] = left_lines['attributes'].apply(lambda x : x.get('gene_id', '-'))
    
    # genes['attributes'] = genes['attribute'].apply(parse_attributes)
    # left_lines['attributes'] = left_lines['attribute'].apply(parse_attributes)
    # left_lines['gene_id'] = left_lines['attributes'].apply(lambda x : x.get('gene_id', '-'))

    return genes, left_lines

def gtf_to_ptt(gtf_file, ptt_file, genome_fasta):
    genes, left_lines = parse_gtf(gtf_file)

    # Get the sequence length from the genome fasta file
    with open(genome_fasta, "r") as handle:
        seq_record = next(SeqIO.parse(handle, "fasta"))
        seq_length = len(seq_record)
    
    with open(ptt_file, 'w') as ptt:
        # ptt.write(f"Chromosome: {seq_record.id}\n")
        # ptt.write(f"{seq_length} bp DNA sequence\n")
        ptt.write(f"{seq_record.description}. - 1..{seq_length}\n")
        ptt.write(f"{len(genes)} proteins\n")
        ptt.write("Location\tStrand\tLength\tPID\tGene\tSynonym\tCode\tCOG\tProduct\n")

        for i, row in genes.iterrows():
            start = row['start']
            end = row['end']
            strand = row['strand']
            
            length = end - start + 1
            length = (length - 3) // 3  # gene - amino acid
            
            gene_id = row['attributes'].get('gene_id', '-')
            gene_name = row['attributes'].get('gene', '-')
            try:
                product = left_lines[left_lines['gene_id'] == gene_id]['attributes'].values[0].get('product','-')
            except:
                product = '-'
            location = f"{start}..{end}"
            
            ptt.write(f"{location}\t{strand}\t{length}\t-\t{gene_name}\t{gene_id}\t-\t-\t{product}\n")

def gtfs_to_ptts():
    data_path = osp.join(save_path, 'datasetsDownloaded')
    
    species = os.listdir(data_path)    
    for i in range(len(species)):        
        genome_fasta = glob.glob(osp.join(data_path, species[i], '*.fna'))[0]
        gtf_filename = glob.glob(osp.join(data_path, species[i], '*.gtf'))[0]
        ptt_filename = osp.join(data_path, species[i], 'genomic.ptt')
        
        gtf_to_ptt(gtf_filename, ptt_filename, genome_fasta)
        
        print('##############################')
        print(i, 'Done.')
        print('##############################', flush=True)

def get_tss():
    accessions = []
    f = open(osp.join(root_path, 'accessions602.csv'))
    file = f.readlines()
    for line in file:
        line_cut = line.replace('\n', '').split(',')[1:]
        accessions.append(line_cut)
    f.close()
    
    tss_dir = osp.join(save_path, 'Rockhopper_Results/')
    if not os.path.exists(tss_dir):
        os.mkdir(tss_dir)
    
    
    k = 3
    # tmp_taxon = ['T05116', 'T02448', 'T01197']  # 1 - SRR24304171, SRR10093214, ERR1815297
    tmp_taxon = ['']  # 2,4,5,6,7,9,10 - None
    # tmp_taxon = ['T04851', 'T02497']  # 3 - SRR25445389, SRR19754254
    # tmp_taxon = ['T07087']  # 8 - ERR3316576
    
    save_dir = osp.join(save_path, 'tss'+str(k))
    if not osp.exists(save_dir):
        os.mkdir(save_dir)
        
    rockhopper_path = '/root/projects/GetGeneExpression/tools/Rockhopper.jar'
    # for i in range(len(accessions)):
    start_i, end_i = (k-1)*60, k*60
    if k == 10:
        start_i = 600
        end_i = 602
    for i in range(start_i, end_i):
        taxon = accessions[i][0]
        accession = accessions[i][-1]

        if taxon in tmp_taxon:
            print(taxon, 'skip.', flush=True)
            continue
        # if not taxon in tmp_taxon:
        #     continue
        
        fastq_dir = osp.join(save_path, 'fasterq_dumps_split'+str(k), accession)
        # fastq_dir = osp.join(save_path, 'fasterq_dumps', accession)
        genomic_dir = osp.join(save_path, 'datasetsDownloaded', taxon)
        
        start = time.time()
        if len(os.listdir(fastq_dir)) == 1:
            # 单端测序
            fastq_path = glob.glob(osp.join(fastq_dir, '*.fastq'))[0]
            
            # 运行前
            # source /etc/profile
            # conda activate base
            run_command(f"java -Xmx1200m -cp {rockhopper_path} Rockhopper -p 32 -o {tss_dir} -g {genomic_dir} {fastq_path}")
        else:
            # 双末端测序
            # 若两种测序方式都有，也选取双末端测序
            fastq_path1 = glob.glob(osp.join(fastq_dir, '*_1.fastq'))[0]
            fastq_path2 = glob.glob(osp.join(fastq_dir, '*_2.fastq'))[0]
            # pdb.set_trace()
            run_command(f"java -Xmx1200m -cp {rockhopper_path} Rockhopper -p 32 -o {tss_dir} -g {genomic_dir} {fastq_path1}%{fastq_path2}")
        run_command(f"mv {tss_dir}/_operons.txt {tss_dir}/{accession}_operons.txt")
        run_command(f"mv {tss_dir}/_transcripts.txt {tss_dir}/{accession}_transcripts.txt")
        run_command(f"mv {tss_dir}/summary.txt {tss_dir}/{accession}.txt")    
        print('Time: {}s'.format(time.time()-start), flush=True)
        # pdb.set_trace()
    run_command(f"mv {tss_dir}/*.txt {save_dir}/")

def filter_tss():
    accessions = pd.read_csv(osp.join(root_path, 'data/accessions602.csv'), header=None)

    tss_dir = osp.join(save_path, 'tss/')
    save_dir = osp.join(save_path, 'tss_filtered2/')
    if not osp.exists(save_dir):
        os.mkdir(save_dir)
    
    tmp_taxon = [
        'T05116', 'T07087',                       # error
        'T02448', 'T01197', 'T04851', 'T02497'    # short genome
    ]
    for i in range(len(accessions)):
        taxon = accessions.iloc[i][1]
        accession = accessions.iloc[i][6]
        
        if taxon in tmp_taxon:
            print(taxon, 'skip.', flush=True)
            continue
        
        handle = open(osp.join(tss_dir, accession+'_transcripts.txt'), 'r')
        file = handle.readlines()
        handle.close()
        
        lines = [file[0].replace('\n', '').split('\t')]
        for line in file[1:]:
            line_cut = line.replace('\n', '').split('\t')
            
            if not len(line_cut) > 1:
                continue
            # if line_cut[0] == '' and line_cut[3] == '':
            #     continue
            if line_cut[0] == '':
                continue
            if 'predicted' in line_cut[6]:
                continue
            if line_cut[0] == line_cut[1]:
                continue
            # if abs(int(line_cut[0]) - int(line_cut[1])) > 140 or abs(int(line_cut[0]) - int(line_cut[1])) < 10:
            #     continue
            
            lines.append(line_cut)
        
        if len(lines) <= 1:
            print(taxon, 'empty.', flush=True)
            continue
            
        data = np.array(lines[1:])
        df = pd.DataFrame(data, columns=lines[0])
        df.to_csv(osp.join(save_dir, accession+'_tss.csv'), sep=',', header=True, index=False)


##### select >40%/>50% #####
def save_transcript_alignment_rate():
    """Extract alignment rates from log file and save to CSV"""                                                                                                                       
    # File paths
    log_file = osp.join(root_path, 'logs/featureCounts.log')
    output_file = osp.join(root_path, 'data/transcript_alignment_rate_prokaryotes.csv')

    # Taxon filter list
    exclude_taxa = ['T05116', 'T02448', 'T01197', 'T04851', 'T02497', 'T07087']
    
    # Read log file
    with open(log_file, 'r') as f:
        content = f.read()

    # Results list
    results = []

    # Regex patterns
    taxon_pattern = r'Output files:.*?/(\w+)/((?:GCF|GCA)_\d+\.\d+)_'
    accession_pattern = r'Output file\s*:\s*((?:SRR|ERR|DRR)\d+)_featureCounts\.txt'
    alignment_pattern = r'([\d.]+)% overall alignment rate'
    assigned_pattern = r'Successfully assigned alignments\s*:\s*\d+\s*\(([\d.]+)%\)'

    # Split log by sample blocks
    sample_blocks = re.split(r'\nSettings:\n', content)

    for block in sample_blocks:
        if not block.strip():
            continue

        # Extract taxon and accession
        output_match = re.search(taxon_pattern, block)
        if not output_match:
            continue
        taxon = output_match.group(1)

        # Skip excluded taxa
        if taxon in exclude_taxa:
            continue
        
        # Extract accession (SRR number)
        accession_match = re.search(accession_pattern, block)
        accession = accession_match.group(1) if accession_match else ''
        
        # Extract alignment rate
        alignment_match = re.search(alignment_pattern, block)
        alignment_rate = alignment_match.group(1) if alignment_match else ''

        # Extract assigned alignment rate
        assigned_match = re.search(assigned_pattern, block)
        assigned_alignment_rate = assigned_match.group(1) if assigned_match else ''

        if taxon and accession:
            results.append({
                'taxon': taxon,
                'accession': accession,
                'alignment_rate': alignment_rate,
                'assigned_alignment_rate': assigned_alignment_rate
            })

    # Write to CSV file
    with open(output_file, 'w', newline='') as f:
        fieldnames = ['taxon', 'accession', 'alignment_rate', 'assigned_alignment_rate']
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    print(f'Extracted {len(results)} records to {output_file}')

def select_from_assigned_alignment_rate():                                                                                                      
    """         
    Filter samples with assigned_alignment_rate greater than threshold and save to new file.                                                                          
                                                                                                                                                                    
    Parameters:
        threshold (float): assigned_alignment_rate threshold
        input_files (str or list): input file path(s), can be a single file or a list of files
    """
    # threshold = 40  # 40%
    threshold = 50  # 50%
    
    filename = 'transcript_alignment_rate_prokaryotes'
    input_file = osp.join(root_path, 'data/'+filename+'.csv')

    df = pd.read_csv(input_file)
    filtered = df[df["assigned_alignment_rate"] > threshold]
    print(f"{filename}: {len(filtered)}/{len(df)} records")
    
    # Auto-generate output filename
    output_filename = f"{filename}>{threshold/100}.csv"
    output_file = osp.join(root_path, 'data/'+output_filename)
    filtered.to_csv(output_file, index=False)

    print(f"\nThreshold >{threshold}%, total {len(filtered)} records, saved to {output_file}")

def select_tpm_gene():
    """
    Select tpm_gene files based on filtered CSV and copy to new directory.
    """
    specie = 'prokaryotes'
    # assigned_alignment_rate = '0.4'
    assigned_alignment_rate = '0.5'
    
    filename = f'transcript_alignment_rate_{specie}>{assigned_alignment_rate}.csv'
    
    file_path = osp.join(root_path, 'data/'+filename)
    df = pd.read_csv(file_path)

    src_dir = osp.join(save_path, 'tpm_gene')
    dst_dir = osp.join(save_path, f'tpm_gene_selected{assigned_alignment_rate}')
    os.makedirs(dst_dir, exist_ok=True)
    
    # Copy files
    copied = 0
    not_found = []

    for _, row in df.iterrows():
        filename = f"{row['taxon']}_{row['accession']}_tpm_gene.txt"
        src_file = os.path.join(src_dir, filename)
        dst_file = os.path.join(dst_dir, filename)

        if os.path.exists(src_file):
            shutil.copy2(src_file, dst_file)
            copied += 1
        else:
            not_found.append(filename)

    print(f"Copied {copied}/{len(df)} files to {dst_dir}")
    if not_found:
        print(f"Not found ({len(not_found)}): {not_found[:5]}{'...' if len(not_found) > 5 else ''}")

def tpm_tss_components():
    """
    Generate TSS components with 12 different cutting schemes (grid search)
    """
    # threshold = 0.4
    threshold = 0.5
    species = 'prokaryotes'
    
    accessions = pd.read_csv(osp.join(root_path, f'data/transcript_alignment_rate_{species}>{threshold}.csv'))
    tpm_gene_dir = osp.join(save_path, f'tpm_gene_selected{threshold}/')
    tss_filtered_dir = osp.join(save_path, 'tss_filtered/')
    base_save_dir = osp.join(save_path, f'tpm_tss_components{threshold}/')
    
    # Grid search parameters
    up_lengths = [10, 20, 30]
    core_lengths = [30, 40, 50, 60]
    
    # Create directories for all 12 combinations
    for up_len in up_lengths:
          for core_len in core_lengths:
              os.makedirs(osp.join(base_save_dir, f"up{up_len}_core{core_len}"), exist_ok=True)
    
    if species == 'prokaryotes':
        prokaryotes_file = pd.read_csv(osp.join(root_path, 'data/accessions602.csv'), header=None)
    
    not_found_count = 0
    for i in range(len(accessions)):
        taxon = accessions.iloc[i][0]
        accession = accessions.iloc[i][1]
        
        if species == 'prokaryotes':
            short_name = prokaryotes_file.loc[prokaryotes_file[1] == taxon, 2].values[0]
        
        # Check tpm_gene file exists
        tpm_file = osp.join(tpm_gene_dir, f"{taxon}_{accession}_tpm_gene.txt")
        print(f"###########################################################")
        print(f"[Processing {i+1}/{len(accessions)}] {taxon}_{accession}_tpm_gene.txt", flush=True)

        if not osp.exists(tpm_file):
            print(f"[Skip] {taxon}_{accession}_tpm_gene.txt not found", flush=True)
            not_found_count += 1
            continue
        else:
            with open(osp.join(tpm_gene_dir, tpm_file), 'r') as f:
                lines = f.readlines()
                tpm_data = [line.strip().split(',') for line in lines[1:] if line.strip()]
                tpm_gene_selected = pd.DataFrame(tpm_data, columns=lines[0].strip().split(','))

        # Check tss_filtered file exists
        tss_file = osp.join(tss_filtered_dir, f"{accession}_tss.csv")
        if not osp.exists(tss_file):
            print(f"[Skip] {taxon} {accession}_tss.csv not found", flush=True)
            continue
        else:
            tss_filtered = pd.read_csv(tss_file)
            if len(tss_filtered) == 0:
                print(f"[Skip] {taxon} {accession}: tss_filtered empty", flush=True)
                continue
        
        # Process for all 12 combinations
        valid_count = 0
        for up_length in up_lengths:
            for core_length in core_lengths:
                combo_dir = osp.join(base_save_dir, f"up{up_length}_core{core_length}")
                output_file = osp.join(combo_dir, f"{taxon}_{accession}_tpm_tss_components.txt")

                with open(output_file, 'w') as f_out:
                    f_out.write('geneId,region_blank,region_up,region_core,region_down,gene,tpm\n')

                    for j in range(len(tss_filtered)):
                        try:
                            transcription_start = tss_filtered.iloc[j]['Transcription Start']
                            translation_start = tss_filtered.iloc[j]['Translation Start']
                            synonym = str(tss_filtered.iloc[j]['Synonym'])
                            
                            if species == 'prokaryotes':
                                geneId = f"{short_name}:{synonym}"
                            else:
                                geneId = synonym
                                
                            # Find matching gene in tpm_gene
                            if geneId not in tpm_gene_selected['geneId'].values:
                                print(taxon, accession, geneId, 'not in the tpm_gene list.', flush=True)
                                continue

                            tpm_gene_index = tpm_gene_selected[tpm_gene_selected['geneId']==geneId].index.values[0]
                            promoter = tpm_gene_selected.iloc[tpm_gene_index]['promoter']
                            gene = tpm_gene_selected.iloc[tpm_gene_index]['gene']
                            tpm = tpm_gene_selected.iloc[tpm_gene_index]['tpm']

                            # Calculate regions                                                                                                                                                            
                            down_length = abs(int(translation_start) - int(transcription_start))                                                                                                           
                            down_start = 200 - down_length                                                                                                                                                 
                            core_start = 200 - down_length - core_length                                                                                                                                   
                            up_start = 200 - down_length - core_length - up_length

                            # Skip if positions invalid (down_length out of valid range)
                            if down_start < 0 or core_start < 0 or down_length < 10:
                                continue

                            # If up_start <= 0, blank region doesn't exist, adjust accordingly
                            if up_start <= 0:
                                region_blank = ''
                                region_up = promoter[0:up_length]  # Start from position 0
                                up_start = 0  # Reset up_start
                            else:
                                region_blank = promoter[:up_start]
                                region_up = promoter[up_start:up_start + up_length]
                            region_down = promoter[down_start:]
                            region_core = promoter[core_start:core_start + core_length]

                            f_out.write(f"{geneId},{region_blank},{region_up},{region_core},{region_down},{gene},{tpm}\n")
                            valid_count += 1
                        except (KeyError, ValueError, TypeError, IndexError):
                            print(f"[Skip] {taxon} {accession} {geneId} error", flush=True)
                            continue

        if valid_count > 0:
            print(f"[Done] {valid_count//12+1}/{len(tpm_gene_selected)} {taxon} {accession}: {valid_count//12} genes", flush=True)
        else:
            print(f"[Skip] {taxon} {accession}: no valid genes", flush=True)

def tpm_tss_components_txt():
    # threshold = 0.4
    threshold = 0.5
    species = 'prokaryotes'
    
    base_dir = osp.join(save_path, f'tpm_tss_components{threshold}')
    save_dir = osp.join(save_path, f'data/components')
    os.makedirs(save_dir, exist_ok=True)
    
    # Grid search parameters
    up_lengths = [10, 20, 30]
    core_lengths = [30, 40, 50, 60]
    
    # Create directories for all 12 combinations
    for up_len in up_lengths:
        for core_len in core_lengths:
            file_list = os.listdir(osp.join(base_dir, f"up{up_len}_core{core_len}"))
            tpm_tss_components = open(osp.join(save_dir, f'tpm_tss_components_{species}{threshold}_up{up_len}_core{core_len}.txt'), 'w')
            tpm_tss_components.write('geneId,region_blank,region_up,region_core,region_down,gene,tpm\n')
            for i in range(len(file_list)):
                handle = open(osp.join(base_dir, f"up{up_len}_core{core_len}", file_list[i]), 'r')
                lines = handle.readlines()
                handle.close()
                
                tpm_tss_components.writelines(lines[1:])
            tpm_tss_components.close()
            print(f"[Done] {up_len}_{core_len}", flush=True)
    print("Done", flush=True)
    
def get_complete_components_tokens():
    model_name_or_path = '/data/p25wuhx/bert_prism/ckpt/pretrained/checkpoint-720000/'
    
    model_max_length = 100
    tokenizer = transformers.AutoTokenizer.from_pretrained(
        model_name_or_path,
        # cache_dir=training_args.cache_dir,
        model_max_length=model_max_length,
        padding_side="right",
        use_fast=True,
        trust_remote_code=True,
    )
    
    save_dir = osp.join(save_path, 'data/components_complete_tokens')
    os.makedirs(save_dir, exist_ok=True)
    
    # threshold = 0.4
    threshold = 0.5
    species = 'prokaryotes'

    # Grid search parameters
    up_lengths = [10, 20, 30]
    core_lengths = [30, 40, 50, 60]
    
    # Create directories for all 12 combinations
    for up_len in up_lengths:
        for core_len in core_lengths:
            filename = f'tpm_tss_components_{species}{threshold}_up{up_len}_core{core_len}'
            file_path = osp.join(save_path, 'data/components', filename+'.txt')
            df = pd.read_csv(file_path, sep=',')
            df = df.fillna('')
            
            sequences = []
            for i in range(len(df)):
                region_blank = df.iloc[i]['region_blank']
                region_up = df.iloc[i]['region_up']
                region_core = df.iloc[i]['region_core']
                region_down = df.iloc[i]['region_down']
                try:
                    promoter = region_blank + region_up + region_core + region_down
                except:
                    pdb.set_trace()
                gene = df.iloc[i]['gene']
                
                seq = promoter + gene
                sequences.append(seq)

            output = tokenizer(
                sequences, 
                return_tensors="np", 
                padding="max_length", 
                max_length=tokenizer.model_max_length, 
                truncation=True
            )
            tokens = output['input_ids']
            masks = output['attention_mask']
            
            if 'newtoken' in model_name_or_path:
                filename += '_newtoken'
            elif 'mergetoken' in model_name_or_path:
                filename += '_mergetoken'
            else:
                pass
            
            np.savez_compressed(os.path.join(save_dir, filename+'.npz'), **{'sequences':tokens, 'masks': masks})
            print(filename, 'done.', flush=True)

def get_split_components_tokens():
    model_name_or_path = '/data/p25wuhx/bert_prism/ckpt/pretrained/checkpoint-720000/'
    
    model_max_length = 100
    tokenizer = transformers.AutoTokenizer.from_pretrained(
        model_name_or_path,
        # cache_dir=training_args.cache_dir,
        model_max_length=model_max_length,
        padding_side="right",
        use_fast=True,
        trust_remote_code=True,
    )

    save_dir = osp.join(save_path, 'data/components_split_tokens')
    os.makedirs(save_dir, exist_ok=True)
    
    threshold = 0.4
    # threshold = 0.5
    species = 'prokaryotes'
    
    # Grid search parameters
    up_lengths = [10, 20, 30]
    core_lengths = [30, 40, 50, 60]
    
    # Create directories for all 12 combinations
    for up_len in up_lengths:
        for core_len in core_lengths:
            filename = f'tpm_tss_components_{species}{threshold}_up{up_len}_core{core_len}'
            file_path = osp.join(save_path, 'data/components', filename+'.txt')
            df = pd.read_csv(file_path, sep=',')
            df = df.fillna('')
            
            if 'newtoken' in model_name_or_path:
                filename += '_newtoken'
            elif 'mergetoken' in model_name_or_path:
                filename += '_mergetoken'
            else:
                pass
            
            complete_output = np.load(osp.join(save_path, 'data/components_complete_tokens', filename+'.npz'))
            complete_tokens = complete_output['sequences']
            complete_masks = complete_output['masks']

            masks_ones = np.ones([len(complete_masks),1], dtype=np.int64)
            # masks_zeros = np.zeros([len(complete_masks),1], dtype=np.int64)
            blank_masked = np.ones_like(complete_masks[:, 1:-1])
            up_masked = np.ones_like(complete_masks[:, 1:-1])
            core_masked = np.ones_like(complete_masks[:, 1:-1])
            down_masked = np.ones_like(complete_masks[:, 1:-1])
            gene_masked = np.ones_like(complete_masks[:, 1:-1])
            intensity = np.zeros([len(complete_masks)], dtype=np.float32)
            
            no_blank_ids = []
            start_time = time.time()
            for i in range(len(df)):
                # geneId = df.iloc[i]['geneId']

                region_blank = df.iloc[i]['region_blank']
                if region_blank == '':
                    # print(i, 'no region_blank.', flush=True)
                    no_blank_ids.append(i)
                    continue
                
                region_up = df.iloc[i]['region_up']
                region_core = df.iloc[i]['region_core']
                region_down = df.iloc[i]['region_down']
                # promoter = region_blank + region_up + region_core + region_down
                gene = df.iloc[i]['gene']
                tpm = df.iloc[i]['tpm']
                
                word_list = tokenizer.decode(complete_tokens[i:i+1][0]).split(' ')[1:-1]
                
                check_seq = region_blank
                tmp_seq = ''
                id_list = [0]
                for j in range(len(word_list)):
                    tmp_seq += word_list[j]
                    if (check_seq in tmp_seq) and (len(tmp_seq) > len(check_seq)):
                        id_list.append(j)
                        if len(id_list) == 2:
                            check_seq += region_up
                        elif len(id_list) == 3:
                            check_seq += region_core
                        elif len(id_list) == 4:
                            check_seq += region_down
                        elif len(id_list) == 5:
                            check_seq += gene
                        else:
                            break
                
                blank_masked[i][id_list[0] : id_list[1]] = 0
                up_masked[i][id_list[1] : id_list[2]] = 0
                core_masked[i][id_list[2] : id_list[3]] = 0
                down_masked[i][id_list[3] : id_list[4]] = 0
                
                # blank_masked[i][id_list[0] : id_list[1]+1] = 0
                # up_masked[i][id_list[1] : id_list[2]+1] = 0
                # core_masked[i][id_list[2] : id_list[3]+1] = 0
                # down_masked[i][id_list[3] : id_list[4]+1] = 0
                
                if len(id_list) >= 5:
                    if len(id_list) == 5:
                        end_pos = len(word_list)
                        for j in range(id_list[4], len(word_list)):
                            if word_list[j] in ['[SEP]', '[PAD]']:
                                end_pos = j
                                break
                        gene_masked[i][id_list[4] : end_pos] = 0
                    elif len(id_list) == 6:
                        gene_masked[i][id_list[4] : id_list[5]] = 0
                else:
                    print(f'Warning: id_list length {len(id_list)} < 5 at index {i}')
                    no_blank_ids.append(i)
                    continue
                intensity[i] = tpm
            # blank_masked = np.concatenate([masks_zeros, blank_masked, masks_zeros], axis=1)
            # up_masked = np.concatenate([masks_zeros, up_masked, masks_zeros], axis=1)
            # core_masked = np.concatenate([masks_zeros, core_masked, masks_zeros], axis=1)
            # down_masked = np.concatenate([masks_zeros, down_masked, masks_zeros], axis=1)
            # gene_masked = np.concatenate([masks_zeros, gene_masked, masks_zeros], axis=1)
            
            blank_masked = np.concatenate([masks_ones, blank_masked, masks_ones], axis=1)
            up_masked = np.concatenate([masks_ones, up_masked, masks_ones], axis=1)
            core_masked = np.concatenate([masks_ones, core_masked, masks_ones], axis=1)
            down_masked = np.concatenate([masks_ones, down_masked, masks_ones], axis=1)
            gene_masked = np.concatenate([masks_ones, gene_masked, masks_ones], axis=1)
            
            if no_blank_ids:
                # Create a boolean mask for rows to keep
                keep_mask = np.ones(len(complete_tokens), dtype=bool)
                keep_mask[no_blank_ids] = False
                
                # Filter out the no_blank_ids rows from all arrays
                complete_tokens = complete_tokens[keep_mask]
                complete_masks = complete_masks[keep_mask]
                blank_masked = blank_masked[keep_mask]
                up_masked = up_masked[keep_mask]
                core_masked = core_masked[keep_mask]
                down_masked = down_masked[keep_mask]
                gene_masked = gene_masked[keep_mask]
                intensity = intensity[keep_mask]
            
            blank_masked[complete_masks == 0] = 0
            up_masked[complete_masks == 0] = 0
            core_masked[complete_masks == 0] = 0
            down_masked[complete_masks == 0] = 0
            gene_masked[complete_masks == 0] = 0
            
            print('Time: {}s'.format(time.time()-start_time), flush=True)
            
            save_name = filename+'_cut'
            
            if 'newtoken' in model_name_or_path:
                save_name += '_newtoken'
            elif 'mergetoken' in model_name_or_path:
                save_name += '_mergetoken'
            else:
                pass
            
            np.savez_compressed(
                os.path.join(save_dir, save_name+'.npz'),
                **{
                    'complete_tokens': complete_tokens,
                    'complete_masks': complete_masks,
                    'blank_masked': blank_masked, 
                    'up_masked': up_masked, 
                    'core_masked': core_masked,
                    'down_masked': down_masked,
                    'gene_masked': gene_masked,
                    'intensity': intensity,
                }
            )
            print(f'Done. Saved to {save_name}.npz', flush=True)

def components_tokens_train_test_split():
    """
    Split data inside each npz file into training and testing sets.

    Args:
        source_dir: Path to the directory containing npz files.
        train_ratio: Ratio of training set (default: 0.8).
        seed: Random seed for reproducibility (default: 42).
    """
    source_dir = save_path + 'data/components_split_tokens'
    train_ratio = 0.8
    seed = 42

    train_dir = source_dir + '_train'
    test_dir = source_dir + '_test'
    os.makedirs(train_dir, exist_ok=True)
    os.makedirs(test_dir, exist_ok=True)

    np.random.seed(seed)
    
    all_files = [f for f in os.listdir(source_dir) if f.endswith('.npz')]
    print(f"Total files: {len(all_files)}", flush=True)
    
    for filename in all_files:
            filepath = os.path.join(source_dir, filename)
            data = np.load(filepath)

            # Get the number of samples from the first array
            keys = list(data.keys())
            n_samples = data[keys[0]].shape[0]

            # Generate random indices for splitting
            indices = np.random.permutation(n_samples)
            split_idx = int(n_samples * train_ratio)
            train_indices = indices[:split_idx]
            test_indices = indices[split_idx:]

            # Split each array and save
            train_data = {}
            test_data = {}

            for key in keys:
                train_data[key] = data[key][train_indices]
                test_data[key] = data[key][test_indices]

            np.savez_compressed(os.path.join(train_dir, filename), **train_data)
            np.savez_compressed(os.path.join(test_dir, filename), **test_data)

            print(f"Processed: {filename} ({n_samples} samples -> {len(train_indices)} train, {len(test_indices)} test)", flush=True)
    print("Split completed!", flush=True)
