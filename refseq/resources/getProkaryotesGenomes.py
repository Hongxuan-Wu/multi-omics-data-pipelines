import os
import numpy as np
import re
# import ncbi_genome_download as ngd
import gzip
import pdb
import time
import sys
MAX_INT=sys.maxsize

from Bio import SeqIO
from Bio.Seq import Seq
from bioservices import KEGG

root = '/root/projects/DNABERT_Promotor/data/'

def getClassificationList():
    '''
        获取KEGG数据库中所有原核生物id、名称、分类
        Sum: 8602
    '''
    
    # 创建 KEGG 对象
    kegg = KEGG()

    # 获取KEGG Organisms: Complete Genomes列表
    organisms = kegg.list('organism').split('\n')
    
    # 过滤出原核生物（通常分类为 "Prokaryotes"）
    prokaryotes = []
    for org in organisms:
        if 'Prokaryotes' in org:
            line = re.split('\t|;', org)
            if not len(line) == 7:
                print(org)
                line.append('')
            prokaryotes.append(line)
    # pdb.set_trace()
    
    data = np.asarray(prokaryotes)
    np.savetxt(os.path.join(root, 'ProkaryotesClassificationList.csv'), data, delimiter=",", fmt='%s')

def getProkaryotesList():
    '''
        根据原核生物id, 获取KEGG数据库中所有原核生物的length、taxonomy、assembly_accessions
        Sum: 8602
    '''
    
    # 创建 KEGG 对象
    kegg = KEGG()

    # 加载原核生物列表
    prokaryotes = []
    with open(os.path.join(root, 'ProkaryotesList.csv')) as f:
        file = f.readlines()
        for line in file:
            prokaryotes.append(line.replace('\n', '').split(','))
    f.close()
    
    start = 8478
    f = open(os.path.join(root, 'Prokaryotes.csv'), 'a')
    for i in range(start, len(prokaryotes)):  # for i in range(start, len(mg1655_locus)):
        genome_info = kegg.parse(kegg.get('genome:'+prokaryotes[i][0]))
        # pdb.set_trace()
        taxonomy = genome_info['TAXONOMY'][0]['TAXONOMY'].split(':')[-1]
        database = genome_info['DATA_SOURCE'].split(')')[0].split(' ')[0]
        if not 'CHROMOSOME' in genome_info.keys():
            dna_length = str(-1)
        else:
            dna_length = genome_info['CHROMOSOME'][0]['LENGTH']
        assembly_accessions = genome_info['DATA_SOURCE'].split(')')[0].split(' ')[-1].split(':')[-1]
        line = str(i) + ',' + prokaryotes[i][0] + ',' + prokaryotes[i][1] + ',' + dna_length + ',' + taxonomy + ',' + database + ',' + assembly_accessions + '\n'
        f.write(line)
        
        print(line)
    f.close()
    # pdb.set_trace()

def getGenesLists():
    '''
        获取KEGG数据库中所有原核生物对应所有基因的id、position
        Sum: 8542
    '''
    
    # 创建 KEGG 对象
    kegg = KEGG()

    # 加载原核生物列表
    prokaryotes = []
    with open(os.path.join(root, 'Prokaryotes.csv')) as f:
        file = f.readlines()
        for line in file:
            prokaryotes.append(line.replace('\n', '').split(','))
    f.close()
    
    genelists_path = '/hy-tmp/prokaryotes/genelists'
    if not os.path.exists(genelists_path):
        os.mkdir(genelists_path)

    # 获取KEGG数据库中每个原核生物的基因列表
    start = 8291
    for i in range(start, len(prokaryotes)):
        gene_list = kegg.list(prokaryotes[i][1])
        if gene_list == 400:
            print(str(i), prokaryotes[i][1], 'error! Skip.')
            continue
        # pdb.set_trace()
        gene_list = gene_list.split('\n')
        
        gene = []
        for j in range(len(gene_list)):
            line = gene_list[j].split('\t')[:3]
            if len(line) == 1:
                # print(line, 'not append.')
                continue
            gene.append(line)
        data = np.array(gene)
        np.savetxt(os.path.join(genelists_path, prokaryotes[i][1]+'.csv'), data, delimiter=",", fmt='%s')
        print(str(i), prokaryotes[i][1], 'saved.')
        
        # pdb.set_trace()
        
def getGenomesFolders():
    '''
        根据原核生物assembly_accessions, 获取所有基因组压缩包
        Sum: 8596
    '''
    
    # 加载原核生物列表
    prokaryotes = []
    with open(os.path.join(root, 'Prokaryotes.csv')) as f:
        file = f.readlines()
        for line in file:
            prokaryotes.append(line.replace('\n', '').split(','))
    f.close()

    download_path = '/hy-tmp/prokaryotes/genomes_zipped'
    unzipped_path = '/hy-tmp/prokaryotes/genomes_unzipped'
    if not os.path.exists(download_path):
        os.mkdir(download_path)
    if not os.path.exists(unzipped_path):
        os.mkdir(unzipped_path)
    for i in range(len(prokaryotes)):
        print(str(i))
        filename_download = os.path.join(download_path, prokaryotes[i][1])
        filename_unzipped = os.path.join(unzipped_path, prokaryotes[i][1])

        cmd_download = 'datasets download genome accession {} --dehydrated --filename {}.zip'.format(prokaryotes[i][-1], filename_download)
        res_download = os.system(cmd_download)
        print(res_download)
        
        cmd_unzip = 'unzip {}.zip -d {}'.format(filename_download, filename_unzipped)
        res_unzip = os.system(cmd_unzip)
        print(res_unzip)
        print()
    
def getGenomes():
    '''
        整理下载路径，获取所有基因组源文件
        /hy-tmp/prokaryotes/ncbi_dataset/fetch.txt
        Sum : 8525
    '''

    # # 加载原核生物列表
    # prokaryotes = []
    # with open(os.path.join(root, 'ProkaryotesTaxIds.csv')) as f:
    #     file = f.readlines()
    #     for line in file:
    #         prokaryotes.append(line.replace('\n', '').split(','))
    # f.close()
    
    # # 汇总links
    # unzipped_path = '/hy-tmp/prokaryotes/genomes_unzipped'
    # links = []
    # for i in range(len(prokaryotes)):
    #     # print(str(i))
    #     filename_unzipped = os.path.join(unzipped_path, prokaryotes[i][1], 'ncbi_dataset/fetch.txt')
    #     if not os.path.exists(filename_unzipped):
    #         print(prokaryotes[i][1], 'has no fetch.txt. Skip.')
    #         continue
    #     f_tmp = open(filename_unzipped, 'r')
    #     file = f_tmp.readlines()[0].replace('\n', '').split('\t')
    #     f_tmp.close()
    #     line = file[0] + '\t' + file[1] + '\t' + '../genomes/'+file[2].split('/')[-1]
    #     links.append(line)
        
    
    # fetch_path = '/hy-tmp/prokaryotes/ncbi_dataset'
    # if not os.path.exists(fetch_path):
    #     os.mkdir(fetch_path)
    # data = np.asarray(links)
    # np.savetxt(os.path.join(fetch_path, 'fetch.txt'), data, fmt='%s')
    
    prokaryotes_path = '/hy-tmp/prokaryotes'
    if not os.path.exists(os.path.join(prokaryotes_path, 'genomes')):
        os.mkdir(os.path.join(prokaryotes_path, 'genomes'))
    # cmd_fetch = 'datasets rehydrate --directory {} --max-workers 30'.format(prokaryotes_path)
    cmd_fetch = 'datasets rehydrate --directory {}'.format(prokaryotes_path)
    res_fetch = os.system(cmd_fetch)

def splitGenomes():
    '''
        切分实际下载到的数据集列表genomes_downloaded.csv，以及未成功下载的数据集列表genomes_error.csv
        Sum: 8525, 77
    '''
    # 加载原核生物列表
    prokaryotes = []
    with open(os.path.join(root, 'Prokaryotes.csv')) as f:
        csv = f.readlines()
        for tmp in csv:
            prokaryotes.append(tmp.replace('\n', '').split(','))    # 8602
    f.close()
    
    dataset_path = '/hy-tmp/prokaryotes/genomes/'
    genomes_filenamelist = os.listdir(dataset_path)      # 8527
    genomes_namelist = []
    for filename in genomes_filenamelist:
        genomes_namelist.append(filename[:15])

    starttime = time.time()
    data_list = []
    error_list = []
    for i in range(len(prokaryotes)):
        if prokaryotes[i][-1] not in genomes_namelist:
            error_list.append(prokaryotes[i])
            print(str(i), prokaryotes[i][1], prokaryotes[i][-1], 'no such file.')
            continue

        idx = genomes_namelist.index(prokaryotes[i][-1])
        filename = genomes_filenamelist[idx]
        data_list.append(prokaryotes[i] + [filename])

        print(str(i), 'appended.')
    print(time.time()-starttime, 's.')

    data = np.array(data_list)  # 8602 - 77 = 8525
    np.savetxt(os.path.join(root, 'genomes_downloaded.csv'), data, delimiter=",", fmt='%s')
    error = np.array(error_list)  # 77
    np.savetxt(os.path.join(root, 'genomes_error.csv'), error, delimiter=",", fmt='%s')

def getGenomesFilteredList():
    '''
        根据gene_list, 和所有已下载的基因组，过滤不存在对应关系的数据
        Sum: 8447
    '''
    # 加载原核生物列表
    f3 = open(os.path.join(root, 'genomes_downloaded.csv'))
    file3 = f3.readlines()
    f3.close()
    prokaryotes = [tmp.replace('\n', '').split(',') for tmp in file3]  # 8525

    # 根据gene_lists目录过滤    
    gene_root = '/hy-tmp/prokaryotes/genelists/'
    gene_filenamelist = os.listdir(gene_root)             # 8542

    prokaryotes_filterd = []
    for i in range(len(prokaryotes)):
        if not prokaryotes[i][1]+'.csv' in gene_filenamelist:
            print(str(i), prokaryotes[i][1], 'not in genomes list.')
            continue
        prokaryotes_filterd.append(prokaryotes[i])       # 8465
    print(len(prokaryotes_filterd))
    
    # 根据基因组dna sequence长度过滤
    dataset_path = '/hy-tmp/prokaryotes/genomes/'
    starttime = time.time()
    prokaryotes_filterd2 = []
    for i in range(len(prokaryotes_filterd)):
    # for i in range(26,27):
        genome_path = os.path.join(dataset_path, prokaryotes_filterd[i][-1])
        seq = [fa.seq for fa in SeqIO.parse(genome_path,  "fasta")][0]
        if not len(seq) == int(prokaryotes_filterd[i][3]):
            # pdb.set_trace()
            print(str(i), len(seq), prokaryotes_filterd[i][3], len(seq)==int(prokaryotes_filterd[i][3]))
            continue
        prokaryotes_filterd2.append(prokaryotes_filterd[i])
    print(time.time()-starttime, 's.')
    
    data = np.array(prokaryotes_filterd2)
    np.savetxt(os.path.join(root, 'genomes_filtered.csv'), data, delimiter=",", fmt='%s')     # 8447
    print('Saved.')

def cutGenes():
    '''
        获取gene和promoter
    '''
    starttime = time.time()

    # 加载原核生物列表
    f = open(os.path.join(root, 'genomes_filtered.csv'))
    file = f.readlines()
    f.close()
    prokaryotes = [tmp.replace('\n', '').split(',') for tmp in file]      # 8447
    
    # 加载所有genomes基因组数据
    dataset_path = '/hy-tmp/prokaryotes/genomes/'
    genomes = {}
    for i in range(len(prokaryotes)):
        genome_path = os.path.join(dataset_path, prokaryotes[i][-1])
        seq = [fa.seq for fa in SeqIO.parse(genome_path,  "fasta")][0]
        if not len(seq) == int(prokaryotes[i][3]):
            print(str(i), len(seq), prokaryotes[i][3], len(seq)==int(prokaryotes[i][3]))
            continue
        genomes[prokaryotes[i][1]] = seq
    print('Genomes loaded. ', time.time()-starttime, 's.')
    
    starttime = time.time()
    genelists_path = '/hy-tmp/prokaryotes/genelists/'
    genelists_filtered_path = '/hy-tmp/prokaryotes/genelists_filtered/'
    genes_path = '/hy-tmp/prokaryotes/genes/'
    if not os.path.exists(genes_path):
        os.mkdir(genes_path)
    if not os.path.exists(genelists_filtered_path):
        os.mkdir(genelists_filtered_path)
    
    start = 0
    for i in range(start, len(prokaryotes)):
        gene_csv_path = os.path.join(genelists_path, prokaryotes[i][1]+'.csv')
        f = open(gene_csv_path)
        csv = f.readlines()
        f.close()

        gene_path = os.path.join(genes_path, prokaryotes[i][1]+'.txt')
        f2 = open(gene_path, 'w')
        
        csv_filtered = []
        count = 0
        for line in csv:
            flag_join = ' '
            flag_complement = ' '
            
            gene_info = line.replace('\n', '').split(',')
            gene_id = gene_info[0]
            gene_position = gene_info[2]
            
            if (not 'join' in gene_position) and (len(gene_info) == 3):   # 非拼接
                if ':' in gene_position:
                    gene_position = gene_position.split(':')[-1]
                if '>' in gene_position:
                    gene_position = gene_position.replace('>', '')
                if '<' in gene_position:
                    gene_position = gene_position.replace('<', '')
                if not 'complement' in gene_position:  # 正链
                    try:
                        startSeq, endSeq = gene_position.split('..')
                    except:
                        continue
                    startSeq = int(startSeq)
                    endSeq = int(endSeq)
                    startPromoter = startSeq - 200
                    if startPromoter < 1:
                        continue
                    gene = genomes[prokaryotes[i][1]][startSeq-1:endSeq]
                    promoter = genomes[prokaryotes[i][1]][startPromoter-1:startSeq-1]
                else:  # 反链
                    flag_complement = 'complement'
                    try:
                        startSeq, endSeq = gene_position.split('(')[-1].split(')')[0].split('..')
                    except:
                        continue
                    startSeq = int(startSeq)
                    endSeq = int(endSeq)
                    endPromoter = endSeq + 200
                    if endPromoter > len(genomes[prokaryotes[i][1]]):
                        continue
                    gene = genomes[prokaryotes[i][1]][startSeq-1:endSeq].complement()[::-1]
                    promoter = genomes[prokaryotes[i][1]][endSeq:endPromoter].complement()[::-1]
            else:
                flag_join = 'joined'   # gene是拼接的
                gene_position = ','.join(gene_info[2:])
                if ':' in gene_position:
                    gene_position = gene_position.split(':')[-1]
                if '>' in gene_position:
                    gene_position = gene_position.replace('>', '')
                if '<' in gene_position:
                    gene_position = gene_position.replace('<', '')
                if not 'complement' in gene_position:  # 正链
                    gene_cuts = gene_position.split('(')[-1].split(')')[0].split(',')
                    gene_cuts = [[int(c) for c in cut.split('..')] for cut in gene_cuts]
                    min_pos = MAX_INT
                    gene = Seq('')
                    for k in range(len(gene_cuts)):
                        try:
                            startSeq, endSeq = gene_cuts[k]
                        except:
                            continue
                        min_pos = min(startSeq, min_pos)
                        gene += genomes[prokaryotes[i][1]][startSeq-1:endSeq]
                    startPromoter = min_pos - 200
                    if startPromoter < 1:
                        continue
                    promoter = genomes[prokaryotes[i][1]][startPromoter-1:min_pos-1]
                else:  # 反链
                    flag_complement = 'complement'
                    gene_cuts = gene_position.split('(')[-1].split(')')[0].split(',')
                    gene_cuts = [[int(c) for c in cut.split('..')] for cut in gene_cuts]
                    max_pos = 0
                    gene = Seq('')
                    for k in range(len(gene_cuts)):
                        try:
                            startSeq, endSeq = gene_cuts[k]
                        except:
                            continue
                        max_pos = max(endSeq, max_pos)
                        gene += genomes[prokaryotes[i][1]][startSeq-1:endSeq]
                    gene = gene.complement()[::-1]
                    endPromoter = max_pos + 200
                    if endPromoter > len(genomes[prokaryotes[i][1]]):
                        continue
                    promoter = genomes[prokaryotes[i][1]][max_pos:endPromoter]
                    promoter = promoter.complement()[::-1]
            
            if not len(promoter) == (promoter.count('A') + promoter.count('T') + promoter.count('G') + promoter.count('C')):
                continue
            if not len(gene) == (gene.count('A') + gene.count('T') + gene.count('G') + gene.count('C')):
                continue
            csv_filtered.append(line.replace('\n', ''))
            newline = gene_id + ',' + str(promoter) + ',' + str(gene) + ',' + flag_complement + ',' + flag_join + '\n'
            f2.write(newline)
            count += 1
        csv_filtered = np.array(csv_filtered)
        np.savetxt(os.path.join(genelists_filtered_path, prokaryotes[i][1]+'.csv'), csv_filtered, delimiter=",", fmt='%s')
        print('No:{}  ID:{}  Name:{} writed. Length:{} Actually length:{}, minus:{}'.format(str(i), prokaryotes[i][0], prokaryotes[i][1], len(csv), count, len(csv)-count))
        f2.close()
        
    print(time.time()-starttime, 's.') 
    print('Done.')

def countNucleotides():
    '''
        Sum_genes: 30766851.  Sum_nucleotides: 29052608673.
        Sum_genes: 30738815.  Sum_nucleotides: 29021488059.
    '''
    genes_root = '/hy-tmp/prokaryotes/genes/'
    
    # 加载原核生物列表
    f = open(os.path.join(root, 'genomes_filtered.csv'))
    file = f.readlines()
    f.close()
    prokaryotes = [tmp.replace('\n', '').split(',') for tmp in file]      # 8447
    
    sum_genes = 0
    sum_nucleotides = 0
    for i in range(len(prokaryotes)):
        gene_path = os.path.join(genes_root, prokaryotes[i][1]+'.txt')
        f = open(gene_path)
        txt = f.readlines()
        f.close()
        
        count_nucleotides = 0
        for line in txt:
            line = line.replace('\n', '').split(',')
            count_nucleotides += len(line[2])
            sum_genes += 1
        sum_nucleotides += count_nucleotides
        print('{}  {}  counted. Nucleotides: {}'.format(str(i), prokaryotes[i][1], count_nucleotides))
    print('Sum_genes: {}.  Sum_nucleotides: {}.'.format(sum_genes, sum_nucleotides))
    
def countMinus():
    filepath = '/root/projects/DNABERT_Promotor/outs/genes.out'
    f = open(filepath)
    file = f.readlines()[1:-2]
    f.close()
    
    minus = []
    for line in file:
        m = line.replace('\n','').split(':')[-1]
        minus.append(int(m))
    # print(minus.sort())
    pdb.set_trace()
    
    
if __name__ == '__main__':
    # getClassificationList()  # 获取KEGG数据库中所有原核生物id、名称、分类 - 分类表：ProkaryotesClassificationList.csv - 8602
    # getProkaryotesList()  # 根据分类表中id, 获取KEGG数据库中所有原核生物的length、taxonomy、assembly_accessions - 信息表Prokaryotes.csv - 8602
    # getGenesLists()  # 根据信息表，获取KEGG数据库中所有原核生物对应所有基因的id、position - /hy-tmp/prokaryotes/genelists/*.csv - 8542
    # getGenomesFolders()  # 根据原核生物assembly_accessions, 获取所有基因组压缩包
    # getGenomes()  # 整理下载路径，获取所有基因组源文件 - /hy-tmp/prokaryotes/ncbi_dataset/fetch.txt - 8525
    # splitGenomes()  # 切分 成功/未成功 下载的数据集列表 - genomes_downloaded.csv / genomes_error.csv - 8525 / 77
    # getGenomesFilteredList()  # 根据genelists, 和genomes_downloaded.csv，过滤不存在对应关系的数据，得到最终列表 - genomes_filtered.csv - 8447
    # cutGenes()  # 对所有genomes切片，获取gene和promoter，并过滤未成功切片的基因 - /hy-tmp/prokaryotes/genes/*.txt - 8447
    # countNucleotides()  # 计算基因总数以及核苷酸总数
    countMinus()
    pass

