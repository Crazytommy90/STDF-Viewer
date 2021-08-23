# distutils: language = c
# cython: language_level=3
#
# cystdf_amalgamation.py - STDF Viewer
# 
# Author: noonchen - chennoon233@foxmail.com
# Created Date: July 12th 2020
# -----
# Last Modified: Sat Jun 19 2021
# Modified By: noonchen
# -----
# Copyright (c) 2020 noonchen
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#



import logging
import numpy as np
import threading as th

cimport numpy as cnp
cimport cython
from cython.view cimport array as cyarray
from cython.parallel import prange

from includes.pthread cimport *
from hashmap_src.hashmap_libc cimport *
from sqlite3_src.sqlite3_libc cimport *
from stdf4_src.stdf4_libc cimport *
from tsqueue_src.tsqueue_libc cimport *

from libc.time cimport time_t, strftime, tm, gmtime, localtime
from libc.stdint cimport *
from libc.math cimport NAN
from libc.string cimport memcpy, strcpy, strrchr, strcmp
from posix.stdio cimport fseeko, ftello
from posix.unistd cimport usleep
from libc.stdio cimport FILE, fopen, fread, fclose, SEEK_SET, SEEK_CUR, SEEK_END, sprintf
from libc.stdlib cimport malloc, free


logger = logging.getLogger("STDF Viewer")


# check host endianness
cdef unsigned int _a  = 256
cdef char *_b = <char*>&_a
cdef bint hostIsLittleEndian = (_b[1] == 1)
# cdef bint needByteSwap = False


##############################
# *** typedefs for stdIO *** #
##############################
# operations
ctypedef enum OPT:
    SET_ENDIAN  = 0
    PARSE       = 1
    FINISH      = 2

# record header
ctypedef struct header:
    uint16_t    rec_len
    uint8_t     rec_typ
    uint8_t     rec_sub

# minimun unit represents a record
ctypedef struct recData:
    uint16_t        recHeader
    uint64_t        offset
    unsigned char*  rawData
    uint16_t        binaryLen

# queue element
ctypedef struct dataCluster:
    STDERR      error
    OPT         operation
    recData*    pData

# arg struct
ctypedef struct parse_arg:
    const char*     filename
    tsQueue*        q
    bint*           p_needByteSwap
    bint*           stopFlag

# *** end of typedefs for stdIO *** #


###########################
# *** funcs for stdIO *** #
###########################
cdef STDERR check_endian(STDF* std, bint* p_needByteSwap) nogil:
    cdef header hData
    if std.fops.stdf_read(std, &hData, sizeof(hData)) == STD_OK:
        if hData.rec_typ == 0 and hData.rec_sub == 10:
            if hData.rec_len == 2:
                p_needByteSwap[0] = False
            elif hData.rec_len == 512:
                p_needByteSwap[0] = True
            else:
                # not a stdf
                return INVAILD_STDF
            return STD_OK
        else:
            # not a stdf
            return INVAILD_STDF
    else:
        # read file failed
        return OS_FAIL


cdef void get_offset(STDF* std, tsQueue* q, bint* p_needByteSwap, bint* stopFlag) nogil:
    cdef header hData
    cdef uint16_t recHeader
    cdef uint64_t offset = 0
    cdef dataCluster *ele

    while True:
        # check stop signal from main thread
        if stopFlag != NULL:
            if stopFlag[0]:
                ele = <dataCluster*>message_queue_message_alloc_blocking(q)
                ele.error = TERMINATE
                ele.operation = FINISH
                message_queue_write(q, ele)
                break
        
        if std.fops.stdf_read(std, &hData, sizeof(hData)) == STD_OK:
            recHeader = MAKE_REC(hData.rec_typ, hData.rec_sub)
            offset += sizeof(hData)  # manually advanced by sizeof header
            # swap if byte order is different
            if p_needByteSwap[0]:
                SwapBytes(&hData.rec_len, sizeof(uint16_t))

            if (recHeader == REC_MIR or recHeader == REC_WCR or recHeader == REC_WIR or recHeader == REC_WRR or
                recHeader == REC_PTR or recHeader == REC_FTR or recHeader == REC_MPR or recHeader == REC_TSR or
                recHeader == REC_PIR or recHeader == REC_PRR or recHeader == REC_HBR or recHeader == REC_SBR or 
                recHeader == REC_PCR):
                # get binaryLen and read rawData
                # alloc memory
                ele = <dataCluster*>message_queue_message_alloc_blocking(q)
                ele.pData = <recData*>malloc(sizeof(recData))
                if ele.pData != NULL:
                    ele.pData.rawData = <unsigned char*>malloc(hData.rec_len)
                    if ele.pData.rawData != NULL:
                        # read rawData
                        if std.fops.stdf_read(std, ele.pData.rawData, hData.rec_len) == STD_OK:
                            # send to queue
                            # ele.pData.rawData[hData.rec_len] = b'\0'  # no need for add NULL at the end, length is record
                            ele.pData.recHeader = recHeader
                            ele.pData.offset = offset
                            ele.pData.binaryLen = hData.rec_len
                            ele.operation = PARSE
                            message_queue_write(q, ele)
                            offset += hData.rec_len  # manually advanced by length of raw data
                        else:
                            # end of file
                            free(ele.pData.rawData)
                            free(ele.pData)
                            ele.pData = NULL
                            ele.error = STD_EOF
                            ele.operation = FINISH
                            message_queue_write(q, ele)
                            break
                    else:
                        free(ele.pData.rawData)
                        free(ele.pData)
                        ele.pData   = NULL
                        ele.error   = NO_MEMORY
                        ele.operation     = FINISH
                        message_queue_write(q, ele)
                        break
                else:
                    free(ele.pData)
                    ele.pData   = NULL
                    ele.error   = NO_MEMORY
                    ele.operation     = FINISH
                    message_queue_write(q, ele)
                    break
                
            else:
                # skip current record
                std.fops.stdf_skip(std, hData.rec_len)
                offset += hData.rec_len  # manually advanced by length of raw data
        else:
            # end of file
            ele = <dataCluster*>message_queue_message_alloc_blocking(q)
            ele.error = STD_EOF
            ele.operation = FINISH
            message_queue_write(q, ele)
            break


cdef void* parse(void* input_args) nogil:
    cdef parse_arg* args = <parse_arg*>input_args
    if (args == NULL or args.filename == NULL or args.q == NULL or
        args.p_needByteSwap == NULL or args.stopFlag == NULL):
        return NULL

    cdef STDF *std = NULL
    cdef tsQueue *q = args.q
    cdef bint* p_needByteSwap = args.p_needByteSwap
    cdef bint* stopFlag = args.stopFlag
    cdef STDERR status, status_reopen
    cdef dataCluster *ele = <dataCluster*>message_queue_message_alloc_blocking(q)

    status = stdf_open(&std, args.filename)

    if status != STD_OK:
        stdf_close(std)
        ele.error   = OS_FAIL
        ele.operation     = FINISH
        message_queue_write(q, ele)
    else:
        status = check_endian(std, p_needByteSwap)
        status_reopen = stdf_reopen(std)
        if status == STD_OK and status_reopen == STD_OK:
            # set endian and start parse
            ele.operation     = SET_ENDIAN
            message_queue_write(q, ele)
            # start parsing file
            get_offset(std, q, p_needByteSwap, stopFlag)
        else:
            ele.error   = status
            ele.operation     = FINISH
            message_queue_write(q, ele)
    stdf_close(std)
    return NULL

# *** end of funcs for stdIO *** #


#########################
# *** STDF Analyzer *** #
#########################
def analyzeSTDF(str filepath):
    cdef bytes filepath_byte = filepath.encode('utf-8')
    cdef const char* fpath = filepath_byte
    cdef str resultLog = ""

    rec_name = {REC_FAR:"FAR",
                REC_ATR:"ATR",
                REC_MIR:"MIR",
                REC_MRR:"MRR",
                REC_PCR:"PCR",
                REC_HBR:"HBR",
                REC_SBR:"SBR",
                REC_PMR:"PMR",
                REC_PGR:"PGR",
                REC_PLR:"PLR",
                REC_RDR:"RDR",
                REC_SDR:"SDR",
                REC_WIR:"WIR",
                REC_WRR:"WRR",
                REC_WCR:"WCR",
                REC_PIR:"PIR",
                REC_PRR:"PRR",
                REC_TSR:"TSR",
                REC_PTR:"PTR",
                REC_MPR:"MPR",
                REC_FTR:"FTR",
                REC_BPS:"BPS",
                REC_EPS:"EPS",
                REC_GDR:"GDR",
                REC_DTR:"DTR",}

    cdef bint stopFlag = False
    cdef tsQueue    q
    cdef pthread_t  th
    cdef dataCluster* item
    cdef uint32_t totalRecord = 0
    cdef void* pRec = NULL

    cdef uint16_t preRecHeader = 0
    cdef int recCnt = 0

    # init queue
    message_queue_init(&q, sizeof(dataCluster), 1024*8)
    # args for parser
    cdef parse_arg args
    args.filename = fpath
    args.q = &q
    args.p_needByteSwap = &needByteSwap
    args.stopFlag = &stopFlag

    pthread_create(&th, NULL, parse, <void*>&args)

    while True:
        item = <dataCluster*>message_queue_read(&q)
        if item == NULL:
            break

        else:
            if item.operation == SET_ENDIAN:
                if needByteSwap:
                    resultLog += "Byte Order: big endian\n"
                else:
                    resultLog += "Byte Order: little endian\n"
            elif item.operation == PARSE:
                if item.pData:
                    if preRecHeader != item.pData.recHeader:
                        # print previous cnt
                        if preRecHeader != 0:
                            resultLog += "%s"%rec_name.get(preRecHeader, "") + " × %d\n"%recCnt if recCnt else "\n"
                            if preRecHeader == REC_PRR or preRecHeader == REC_WRR:
                                resultLog += "\n"
                        # update new
                        preRecHeader = item.pData.recHeader
                        recCnt = 1
                    else:
                        recCnt += 1

                    totalRecord += 1
                    free(item.pData.rawData)
                free(item.pData)
            else:
                if recCnt != 0 and preRecHeader != 0:
                    # print last record
                    resultLog += "%s"%rec_name.get(preRecHeader, "") + " × %d\n"%recCnt if recCnt else "\n"

                # check error
                if item.error:
                    if item.error == INVAILD_STDF:
                        resultLog += "INVAILD_STDF\n"
                    elif item.error == WRONG_VERSION:
                        resultLog += "WRONG_VERSION\n"
                    elif item.error == OS_FAIL:
                        resultLog += "OS_FAIL\n"
                    elif item.error == NO_MEMORY:
                        resultLog += "NO_MEMORY\n"
                    elif item.error == STD_EOF:
                        resultLog += "STD_EOF\n"
                    elif item.error == TERMINATE:
                        resultLog += "TERMINATE\n"
                    else:
                        resultLog += "Unknwon error\n"
                break

        message_queue_message_free(&q, item)
    
    pthread_join(th, NULL)
    pthread_kill(th, 0)
    message_queue_destroy(&q)
    resultLog += "\nTotal record: %d\n"%totalRecord
    resultLog += "Analysis Finished"
    return resultLog

# *** end of Record Analyzer *** #


##################################
# *** funcs of Record Parser *** #
##################################
NPINT = int
NPDOUBLE = np.double
ctypedef cnp.int_t NPINT_t
ctypedef cnp.double_t NPDOUBLE_t
cdef bint* p_needByteSwap = &needByteSwap
cdef bint py_needByteSwap = False


def setByteSwap(bint ON_OFF):
    # switch byte swap on/off from python
    global py_needByteSwap
    py_needByteSwap = ON_OFF


@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef int32_t max(int32_t[:] inputArray) nogil:
    cdef int i
    cdef Py_ssize_t size = inputArray.shape[0]
    cdef int32_t result = inputArray[0]

    for i in range(size):
        if inputArray[i] > result:
            result = inputArray[i]

    return result


@cython.boundscheck(False)
@cython.wraparound(False)
def parse_rawList(uint16_t recHeader, int64_t[:] offsetArray, int32_t[:] lengthArray, object file_handle):
    cdef int i
    cdef void* pRec
    cdef Py_ssize_t cnt = offsetArray.shape[0]
    cdef int32_t maxL = max(lengthArray)

    # data containers & views for nogil operation
    cdef cnp.ndarray[NPDOUBLE_t, ndim=1] dataList = np.full(cnt, NAN, dtype=NPDOUBLE)
    cdef cnp.ndarray[NPINT_t, ndim=1] flagList = np.zeros(cnt, dtype=NPINT)
    cdef NPDOUBLE_t[:] dataList_view = dataList
    cdef NPINT_t   [:] flagList_view = flagList

    if maxL < 0:
        # no valid result
        return {"dataList":dataList, "flagList":flagList}

    # memoryView to store raw bytes from file
    cdef const unsigned char[:,:] rawDataView = cyarray(shape = (cnt, maxL),
                                                        itemsize = sizeof(unsigned char),
                                                        format="B")
    # c-contiguous view for accepting bytes from read()
    cdef const unsigned char[::1] tmpData = cyarray(shape = (maxL,),
                                                    itemsize = sizeof(unsigned char),
                                                    format="B")

    # output dict
    cdef dict testDict = {}
    
    # read raw data
    for i in range(cnt):
        if offsetArray[i] < 0 or lengthArray[i] < 0:
            # rawDataView[i, :] = b'\0'    # represent invalid rawData
            lengthArray[i] = -1

        else:
            file_handle.seek(offsetArray[i])
            # we need to append extra bytes at the end of tmpData if maxL > lengthArray[i]
            # otherwise the size mismatch error would be raised by the later copy process
            tmpData = file_handle.read(lengthArray[i]) + b'\0' * (maxL - lengthArray[i])
            rawDataView[i, :] = tmpData

    # set C extern variable to the value from python side
    global p_needByteSwap, py_needByteSwap
    p_needByteSwap[0] = py_needByteSwap
    # parse raw bytes
    for i in prange(cnt, nogil=True):
        if lengthArray[i] < 0:
            dataList_view[i] = NAN
            flagList_view[i] = 0
        else:
            parse_record(&pRec, recHeader, &rawDataView[i,0], lengthArray[i])

            if recHeader == REC_PTR:
                flagList_view[i] = (<PTR*>pRec).TEST_FLG
                dataList_view[i] = (<PTR*>pRec).RESULT
            elif recHeader == REC_FTR:
                flagList_view[i] = (<FTR*>pRec).TEST_FLG
                dataList_view[i] = <NPDOUBLE_t>flagList_view[i]
            else:
                flagList_view[i] = (<MPR*>pRec).TEST_FLG
                dataList_view[i] = <NPDOUBLE_t>flagList_view[i]
            
            free_record(recHeader, pRec)
            pRec = NULL

    return {"dataList":dataList, "flagList":flagList}

# *** end of Record Parser *** #


################################################
# ** Wrappers of standard sqlite3 functions ** #
################################################
# close sqlite3 database
cdef void csqlite3_close(sqlite3 *db):
    cdef int exitcode
    cdef const char *errMsg

    exitcode = sqlite3_close(db)
    if exitcode != SQLITE_OK:
        errMsg = sqlite3_errmsg(db)
        raise Exception(errMsg.decode('UTF-8'))


# open sqlite3 database
cdef void csqlite3_open(str dbPath, sqlite3 **db_ptr):
    cdef bytes dbPath_utf8 = dbPath.encode('UTF-8')
    cdef char *fpath = dbPath_utf8
    cdef const char *errMsg
    cdef int exitcode

    exitcode = sqlite3_open(fpath, db_ptr)
    if exitcode != SQLITE_OK:
        errMsg = sqlite3_errmsg(db_ptr[0])
        raise Exception(errMsg.decode('UTF-8'))


# execute sqlite3 query
cdef void csqlite3_exec(sqlite3 *db, const char *sql):
    cdef int exitcode
    cdef char *errMsg

    exitcode = sqlite3_exec(db, sql, NULL, NULL, &errMsg)
    if exitcode != SQLITE_OK:
        raise Exception(errMsg.decode('UTF-8'))

# *** The following sqlite3 funcs will be called massive times, 
# *** use error code instead of python exception
# prepare sqlite3 statement
cdef int csqlite3_prepare_v2(sqlite3 *db, const char *Sql, sqlite3_stmt **ppStmt) nogil:
    cdef int exitcode
    # cdef const char *errMsg

    exitcode = sqlite3_prepare_v2(db, Sql, -1, ppStmt, NULL)
    if exitcode != SQLITE_OK:
        return exitcode
    else:
        return 0


# execute sqlite3 statement and reset/clear
cdef int csqlite3_step(sqlite3_stmt *stmt) nogil:
    cdef int exitcode
    # cdef const char *errMsg

    exitcode = sqlite3_step(stmt)
    # clear bindings and reset stmt for next step
    sqlite3_reset(stmt)
    sqlite3_clear_bindings(stmt)

    if exitcode != SQLITE_DONE:
        return exitcode
    else:
        return 0


cdef int csqlite3_finalize(sqlite3_stmt *stmt) nogil:
    cdef int exitcode
    # cdef const char *errMsg

    exitcode = sqlite3_finalize(stmt)
    if exitcode != SQLITE_OK:
        return exitcode
    else:
        return 0

# ** End of Wrappers ** #


#################################################
# ** Callback function for iterating hashmap ** #
#################################################
cdef int writeFailCount(void* sql_stmt, uint32_t TEST_NUM, uint32_t count) nogil:
    cdef sqlite3_stmt* updateFailCount_stmt = <sqlite3_stmt*>sql_stmt
    cdef int err = 0
    sqlite3_bind_int(updateFailCount_stmt, 1, count)
    sqlite3_bind_int(updateFailCount_stmt, 2, TEST_NUM)
    err = csqlite3_step(updateFailCount_stmt)
    return err

# ** End of Callback ** #


cdef uint64_t getFileSize(const char* filepath) nogil:
    cdef uint64_t fsize
    cdef uint32_t gz_fsize = 0   # for gz file only
    cdef FILE* fd
    cdef char* ext = strrchr(filepath, 0x2E)    # 0x2E = '.'

    fd = fopen(filepath, "rb")
    if fd == NULL:
        fsize = 0

    if (ext and (not strcmp(ext, ".gz"))):
        # for gzip, read last 4 bytes as filesize
        fseeko(fd, -4, SEEK_END)
        fread(&gz_fsize, 4, 1, fd)
        fsize = <uint64_t>(gz_fsize)
    else:
        # bzip file size is not known before uncompressing, return compressed file size instead
        fseeko(fd, 0, SEEK_END)
        fsize = <uint64_t>ftello(fd)
    fclose(fd)
    return fsize


cdef class stdfSummarizer:
    cdef:
        object QSignal, flag, pb_thread
        uint64_t offset, fileSize
        uint32_t dutIndex, waferIndex
        bint reading, isLittleEndian, stopFlag
        dict pinDict
        bytes filepath_bt
        void* pRec
        char* endian
        char* TEST_TXT
        const char* filepath_c
        sqlite3 *db_ptr
        sqlite3_stmt *insertFileInfo_stmt
        sqlite3_stmt *insertDut_stmt
        sqlite3_stmt *updateDut_stmt
        sqlite3_stmt *insertTR_stmt
        # sqlite3_stmt *updateTR_stmt
        sqlite3_stmt *insertTestInfo_stmt
        sqlite3_stmt *insertHBIN_stmt
        # sqlite3_stmt *updateHBIN_stmt
        sqlite3_stmt *insertSBIN_stmt
        # sqlite3_stmt *updateSBIN_stmt
        sqlite3_stmt *insertWafer_stmt
        sqlite3_stmt *insertDutCount_stmt
        map_t   seenTN          # ele: TEST_NUM
        map_t   TestFailCount
        map_t   head_site_dutIndex
        map_t   head_waferIndex


    def __cinit__(self):
        self.db_ptr                 = NULL
        self.insertFileInfo_stmt    = NULL
        self.insertDut_stmt         = NULL
        self.updateDut_stmt         = NULL
        self.insertTR_stmt          = NULL
        # self.updateTR_stmt          = NULL
        self.insertTestInfo_stmt    = NULL
        self.insertHBIN_stmt        = NULL
        # self.updateHBIN_stmt        = NULL
        self.insertSBIN_stmt        = NULL
        # self.updateSBIN_stmt        = NULL
        self.insertDutCount_stmt    = NULL
        self.insertWafer_stmt       = NULL
        self.pRec                   = NULL
        self.seenTN                 = NULL
        self.TestFailCount          = NULL
        self.head_site_dutIndex     = NULL
        self.head_waferIndex        = NULL


    def __init__(self, QSignal=None, flag=None, filepath=None, dbPath="test.db"):
        # init database in C
        cdef:
            const char* createTableSql = '''DROP TABLE IF EXISTS File_Info;
                                        DROP TABLE IF EXISTS Dut_Info;
                                        DROP TABLE IF EXISTS Test_Info;
                                        DROP TABLE IF EXISTS Test_Offsets;
                                        DROP TABLE IF EXISTS Bin_Info;
                                        DROP TABLE IF EXISTS Wafer_Info;
                                        VACUUM;
                                        
                                        CREATE TABLE IF NOT EXISTS File_Info (
                                                                Field TEXT, 
                                                                Value TEXT);
                                                                
                                        CREATE TABLE IF NOT EXISTS Wafer_Info (
                                                                HEAD_NUM INTEGER, 
                                                                WaferIndex INTEGER PRIMARY KEY,
                                                                PART_CNT INTEGER,
                                                                RTST_CNT INTEGER,
                                                                ABRT_CNT INTEGER,
                                                                GOOD_CNT INTEGER,
                                                                FUNC_CNT INTEGER,
                                                                WAFER_ID TEXT,
                                                                FABWF_ID TEXT,
                                                                FRAME_ID TEXT,
                                                                MASK_ID TEXT,
                                                                USR_DESC TEXT,
                                                                EXC_DESC TEXT);
                                                                
                                        CREATE TABLE IF NOT EXISTS Dut_Info (
                                                                HEAD_NUM INTEGER, 
                                                                SITE_NUM INTEGER, 
                                                                DUTIndex INTEGER PRIMARY KEY,
                                                                TestCount INTEGER,
                                                                TestTime INTEGER,
                                                                PartID TEXT,
                                                                HBIN INTEGER,
                                                                SBIN INTEGER,
                                                                Flag INTEGER,
                                                                WaferIndex INTEGER,
                                                                XCOORD INTEGER,
                                                                YCOORD INTEGER) WITHOUT ROWID;
                                                                
                                        CREATE TABLE IF NOT EXISTS Dut_Counts (
                                                                HEAD_NUM INTEGER, 
                                                                SITE_NUM INTEGER, 
                                                                PART_CNT INTEGER,
                                                                RTST_CNT INTEGER,
                                                                ABRT_CNT INTEGER,
                                                                GOOD_CNT INTEGER,
                                                                FUNC_CNT INTEGER);

                                        CREATE TABLE IF NOT EXISTS Test_Info (
                                                                TEST_NUM INTEGER PRIMARY KEY, 
                                                                recHeader INTEGER,
                                                                TEST_NAME TEXT,
                                                                RES_SCAL INTEGER,
                                                                LLimit INTEGER,
                                                                HLimit INTEGER,
                                                                Unit TEXT,
                                                                OPT_FLAG INTEGER,
                                                                FailCount INTEGER);
                                                                
                                        CREATE TABLE IF NOT EXISTS Test_Offsets (
                                                                DUTIndex INTEGER,
                                                                TEST_NUM INTEGER, 
                                                                Offset INTEGER,
                                                                BinaryLen INTEGER,
                                                                PRIMARY KEY (DUTIndex, TEST_NUM)) WITHOUT ROWID;
                                                                
                                        CREATE TABLE IF NOT EXISTS Bin_Info (
                                                                BIN_TYPE TEXT,
                                                                BIN_NUM INTEGER, 
                                                                BIN_NAME TEXT,
                                                                BIN_PF TEXT,
                                                                PRIMARY KEY (BIN_TYPE, BIN_NUM));
                                                                
                                        DROP INDEX IF EXISTS dutKey;
                                        PRAGMA synchronous = OFF;
                                        PRAGMA journal_mode = WAL;
                                        
                                        BEGIN;'''
            const char* insertFileInfo = '''INSERT INTO File_Info VALUES (?,?)'''
            const char* insertDut = '''INSERT INTO Dut_Info (HEAD_NUM, SITE_NUM, DUTIndex) VALUES (?,?,?);'''
            const char* updateDut = '''UPDATE Dut_Info SET TestCount=:TestCount, TestTime=:TestTime, PartID=:PartID, 
                                                            HBIN=:HBIN_NUM, SBIN=:SBIN_NUM, Flag=:Flag, 
                                                            WaferIndex=:WaferIndex, XCOORD=:XCOORD, YCOORD=:YCOORD 
                                                            WHERE DUTIndex=:DUTIndex; COMMIT; BEGIN;'''     # commit and start another transaction in PRR
            const char* insertTR = '''INSERT OR REPLACE INTO Test_Offsets VALUES (:DUTIndex, :TEST_NUM, :Offset ,:BinaryLen);'''
            # update TR is not required since 'REPLACE' can replace it, and we can save memory to stop tracking test_num and dutIndex, hooray~~
            # const char* updateTR = '''UPDATE Test_Offsets SET Offset=:Offset , BinaryLen=:BinaryLen WHERE DUTIndex=:DUTIndex AND TEST_NUM=:TEST_NUM;'''

            # I am not adding IGNORE below, since tracking seen test_nums can skip a huge amount of codes
            const char* insertTestInfo = '''INSERT INTO Test_Info VALUES (:TEST_NUM, :recHeader, :TEST_NAME, 
                                                                        :RES_SCAL, :LLimit, :HLimit, 
                                                                        :Unit, :OPT_FLAG, :FailCount);'''
            const char* insertHBIN = '''INSERT OR REPLACE INTO Bin_Info VALUES ("H", :HBIN_NUM, :HBIN_NAME, :PF);'''
            # const char* updateHBIN = '''UPDATE Bin_Info SET BIN_NAME=:HBIN_NAME, BIN_PF=:BIN_PF WHERE BIN_TYPE="H" AND BIN_NUM=:HBIN_NUM'''
            const char* insertSBIN = '''INSERT OR REPLACE INTO Bin_Info VALUES ("S", :SBIN_NUM, :SBIN_NAME, :PF);'''
            # const char* updateSBIN = '''UPDATE Bin_Info SET BIN_NAME=:SBIN_NAME, BIN_PF=:BIN_PF WHERE BIN_TYPE="S" AND BIN_NUM=:SBIN_NUM'''
            const char* insertDutCount = '''INSERT INTO Dut_Counts VALUES (:HEAD_NUM, :SITE_NUM, :PART_CNT, :RTST_CNT, 
                                                                        :ABRT_CNT, :GOOD_CNT, :FUNC_CNT);'''
            const char* insertWafer = '''INSERT OR REPLACE INTO Wafer_Info VALUES (:HEAD_NUM, :WaferIndex, :PART_CNT, :RTST_CNT, :ABRT_CNT, 
                                                                                :GOOD_CNT, :FUNC_CNT, :WAFER_ID, :FABWF_ID, :FRAME_ID, 
                                                                                :MASK_ID, :USR_DESC, :EXC_DESC);'''

        # init sqlite3 database api
        try:
            csqlite3_open(dbPath, &self.db_ptr)
            csqlite3_exec(self.db_ptr, createTableSql)
            csqlite3_prepare_v2(self.db_ptr, insertFileInfo, &self.insertFileInfo_stmt)
            csqlite3_prepare_v2(self.db_ptr, insertDut, &self.insertDut_stmt)
            csqlite3_prepare_v2(self.db_ptr, updateDut, &self.updateDut_stmt)
            csqlite3_prepare_v2(self.db_ptr, insertTR, &self.insertTR_stmt)
            # csqlite3_prepare_v2(self.db_ptr, updateTR, &self.updateTR_stmt)
            csqlite3_prepare_v2(self.db_ptr, insertTestInfo, &self.insertTestInfo_stmt)
            csqlite3_prepare_v2(self.db_ptr, insertHBIN, &self.insertHBIN_stmt)
            # csqlite3_prepare_v2(self.db_ptr, updateHBIN, &self.updateHBIN_stmt)
            csqlite3_prepare_v2(self.db_ptr, insertSBIN, &self.insertSBIN_stmt)
            # csqlite3_prepare_v2(self.db_ptr, updateSBIN, &self.updateSBIN_stmt)
            csqlite3_prepare_v2(self.db_ptr, insertDutCount, &self.insertDutCount_stmt)
            csqlite3_prepare_v2(self.db_ptr, insertWafer, &self.insertWafer_stmt)
        except Exception:
            csqlite3_close(self.db_ptr)
            raise

        # get file size in Bytes
        if not isinstance(filepath, str):
            raise TypeError("File path is not type <str>")
        # get c string filepath and file size
        self.filepath_bt = filepath.encode("utf-8")
        self.filepath_c = self.filepath_bt      # for parser in pthread
        self.fileSize = getFileSize(self.filepath_c)
        if self.fileSize == 0:
            raise OSError("File cannot be opened")
        # python signal
        self.flag = flag
        self.QSignal = QSignal
        # current position
        self.offset = 0
        self.reading = True
        # no need to update progressbar if signal is None
        if self.QSignal: 
            self.QSignal.emit(0)
            self.pb_thread = th.Thread(target=self.sendProgress)
            self.pb_thread.start()
        # default endianness & byteswap
        self.endian = "Little endian"
        self.isLittleEndian = True
        self.stopFlag = False
        # used for recording TR, TestNum, HBR, SBR that have been seen
        self.seenTN                 = hashmap_new(1024)
        self.TestFailCount          = hashmap_new(1024)   # key: test number, value: fail count
        self.head_site_dutIndex     = hashmap_new(8)      # key: head numb << 8 | site num, value: dutIndex, a tmp dict used to retrieve dut index by head/site info, required by multi head stdf files
        self.head_waferIndex        = hashmap_new(8)      # similar to head_site_dutIndex, but one head per wafer
        
        if self.seenTN == NULL or self.seenTN == NULL or self.seenTN == NULL:
            hashmap_free(self.seenTN)
            hashmap_free(self.TestFailCount)
            hashmap_free(self.head_site_dutIndex)
            hashmap_free(self.head_waferIndex)            
            raise MemoryError("No enough memory to start parsing")
        # for counting
        self.dutIndex = 0  # get 1 as index on first +1 action, used for counting total DUT number
        self.waferIndex = 0 # used for counting total wafer number
        self.pinDict = {}   # key: Pin index, value: Pin name
        
        self.analyze()  # start
    
    
    def sendProgress(self):
        cdef int percent
        while self.reading:
            with nogil:
                percent = (10000 * self.offset) // self.fileSize     # times additional 100 to save 2 decimal
                usleep(100000)      # wait for 100 ms
            
            self.QSignal.emit(percent)        
            if self.flag.stop:
                (&self.stopFlag)[0] = <bint>self.flag.stop
                break
                
        
        
    cdef void set_endian(self) nogil:
        global hostIsLittleEndian
        if needByteSwap:
            if hostIsLittleEndian:
                self.endian = "Big endian"   # big endian
            else:
                self.endian = "Little endian"   # little endian
        else:
            # same as host
            if hostIsLittleEndian:
                self.endian = "Little endian"
            else:
                self.endian = "Big endian"
        
        
    def analyze(self):
        # global needByteSwap
        cdef int errorCode = 0
        cdef tsQueue    parseQ
        cdef pthread_t  pth
        cdef dataCluster* item
        cdef parse_arg args

        # init c queue
        if message_queue_init(&parseQ, sizeof(dataCluster), 2**22) != 0:
            raise MemoryError("Unable to start parsing queue")
        # args for parser
        args.filename = self.filepath_c
        args.q = &parseQ
        args.p_needByteSwap = &needByteSwap
        args.stopFlag = &self.stopFlag
        # start parsing thread
        if pthread_create(&pth, NULL, parse, <void*>&args) != 0:
            raise RuntimeError("Failed to start parsing thread")
        
        try:
            with nogil:
                while True:
                    item = <dataCluster*>message_queue_read(&parseQ)
                    if item == NULL:
                        break

                    else:
                        if item.operation == SET_ENDIAN:
                            self.set_endian()

                        elif item.operation == PARSE:
                            if item.pData:
                                self.offset = item.pData.offset
                                errorCode = self.onRec(recHeader=item.pData.recHeader, \
                                                        binaryLen=item.pData.binaryLen, \
                                                        rawData=item.pData.rawData)
                                free(item.pData.rawData)
                            free(item.pData)
                            if errorCode: break
                        else:
                            # save error code if finished
                            if item.error:
                                errorCode = item.error
                            break

                    message_queue_message_free(&parseQ, item)

            if errorCode:
                raise Exception

        except Exception:
            if errorCode == INVAILD_STDF:
                raise Exception("The file is not a valid STDF")
            elif errorCode == WRONG_VERSION:
                raise NotImplementedError("Only STDF version 4 is supported")
            elif errorCode == OS_FAIL:
                raise OSError("Cannot open the file")
            elif errorCode == NO_MEMORY or errorCode == MAP_OMEM:
                raise MemoryError("Not enough memory to proceed")
            elif errorCode == STD_EOF:
                pass    # ignore EOF
            elif errorCode == TERMINATE:
                raise InterruptedError("Parsing is terminated by user")
            elif errorCode == MAP_MISSING:
                raise KeyError("Unable to get DUT id correctly, possibly a mal-formated file")
            else:
                # sqlite3 error
                raise Exception(f"SQlite3 Error: {sqlite3_errstr(errorCode)}")

        finally:
            # join progress bar thread if finished
            pthread_join(pth, NULL)
            pthread_kill(pth, 0)
            message_queue_destroy(&parseQ)
            self.after_complete()
        
        
    def after_complete(self):
        cdef:
            uint32_t TEST_NUM, count

        self.reading = False
        # update failcount
        cdef const char* updateFailCount = '''UPDATE Test_Info SET FailCount=:count WHERE TEST_NUM=:TEST_NUM'''
        cdef sqlite3_stmt* updateFailCount_stmt
        csqlite3_prepare_v2(self.db_ptr, updateFailCount, &updateFailCount_stmt)

        hashmap_iterate(self.TestFailCount, <PFany>writeFailCount, updateFailCount_stmt)
        csqlite3_finalize(updateFailCount_stmt)
        
        cdef char* createIndex_COMMIT = '''CREATE INDEX dutKey ON Dut_Info (
                                        HEAD_NUM	ASC,
                                        SITE_NUM	ASC);
                                        
                                        COMMIT;'''
        csqlite3_exec(self.db_ptr, createIndex_COMMIT)
        csqlite3_finalize(self.insertFileInfo_stmt)
        csqlite3_finalize(self.insertDut_stmt)
        csqlite3_finalize(self.updateDut_stmt)
        csqlite3_finalize(self.insertTR_stmt)
        # csqlite3_finalize(self.updateTR_stmt)
        csqlite3_finalize(self.insertTestInfo_stmt)
        csqlite3_finalize(self.insertHBIN_stmt)
        # csqlite3_finalize(self.updateHBIN_stmt)
        csqlite3_finalize(self.insertSBIN_stmt)
        # csqlite3_finalize(self.updateSBIN_stmt)
        csqlite3_finalize(self.insertDutCount_stmt)
        csqlite3_finalize(self.insertWafer_stmt)
        csqlite3_close(self.db_ptr)
        # clean hashmap
        hashmap_free(self.seenTN)
        hashmap_free(self.TestFailCount)
        hashmap_free(self.head_site_dutIndex)
        hashmap_free(self.head_waferIndex)            
        
        if self.QSignal: 
            self.pb_thread.join()
            # update once again when finished, ensure the progress bar hits 100%
            self.QSignal.emit(10000)
        
        
    cdef int onRec(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        # most frequent records on top to reduce check times
        # in Cython it will be replaced by switch case, which will be more efficient than py_dict/if..else
        cdef int err = 0
        if recHeader == 3850 or recHeader == 3855 or recHeader == 3860: # PTR 3850 # MPR 3855 # FTR 3860
            err = self.onTR(recHeader, binaryLen, rawData)
        elif recHeader == 1290: # PIR 1290
            err = self.onPIR(recHeader, binaryLen, rawData)
        elif recHeader == 1300: # PRR 1300
            err = self.onPRR(recHeader, binaryLen, rawData)
        elif recHeader == 522: # WIR 522
            err = self.onWIR(recHeader, binaryLen, rawData)
        elif recHeader == 532: # WRR 532
            err = self.onWRR(recHeader, binaryLen, rawData)
        elif recHeader == 2590: # TSR 2590
            err = self.onTSR(recHeader, binaryLen, rawData)
        elif recHeader == 296: # HBR 296
            err = self.onHBR(recHeader, binaryLen, rawData)
        elif recHeader == 306: # SBR 306
            err = self.onSBR(recHeader, binaryLen, rawData)
        elif recHeader == 316: # PMR 316
            err = self.onPMR(recHeader, binaryLen, rawData)
        elif recHeader == 266: # MIR 266
            err = self.onMIR(recHeader, binaryLen, rawData)
        elif recHeader == 542: # WCR 542
            err = self.onWCR(recHeader, binaryLen, rawData)
        elif recHeader == 286: # PCR 286
            err = self.onPCR(recHeader, binaryLen, rawData)
        return err
            
        # FAR 10
        # ATR 20
        # MRR 276
        # PGR 318
        # PLR 319
        # RDR 326
        # SDR 336
        # BPS 5130
        # EPS 5140
        # GDR 12810
        # DTR 12830
        

    cdef int onMIR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef int err = 0
        cdef time_t timeStamp
        cdef tm*    tmPtr
        cdef char   stringBuffer[256]
        parse_record(&self.pRec, recHeader, rawData, binaryLen)

        # Endianess
        if not err:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "BYTE_ORD", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, self.endian, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # U4  SETUP_T
        if not err:
            timeStamp = <time_t>((<MIR*>self.pRec).SETUP_T)
            tmPtr = localtime(&timeStamp)
            strftime(stringBuffer, 26, "%Y-%m-%d %H:%M:%S (UTC)", tmPtr)
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "SETUP_T", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # U4  START_T
        if not err:
            timeStamp = <time_t>((<MIR*>self.pRec).START_T)
            tmPtr = localtime(&timeStamp)
            strftime(stringBuffer, 26, "%Y-%m-%d %H:%M:%S (UTC)", tmPtr)
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "START_T", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # U1  STAT_NUM
        if not err:
            sprintf(stringBuffer, "%d", (<MIR*>self.pRec).STAT_NUM)
            stringBuffer[1] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "STAT_NUM", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # C1  MODE_COD
        if not err and (<MIR*>self.pRec).MODE_COD != 0x20:    # hex of SPACE
            sprintf(stringBuffer, "%c", (<MIR*>self.pRec).MODE_COD)
            stringBuffer[1] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "MODE_COD", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # C1  RTST_COD
        if not err and (<MIR*>self.pRec).RTST_COD != 0x20:    # hex of SPACE
            sprintf(stringBuffer, "%c", (<MIR*>self.pRec).RTST_COD)
            stringBuffer[1] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "RTST_COD", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # C1  PROT_COD
        if not err and (<MIR*>self.pRec).PROT_COD != 0x20:    # hex of SPACE
            sprintf(stringBuffer, "%c", (<MIR*>self.pRec).PROT_COD)
            stringBuffer[1] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "PROT_COD", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # U2  BURN_TIM
        if not err and (<MIR*>self.pRec).BURN_TIM != 65535:
            sprintf(stringBuffer, "%d", (<MIR*>self.pRec).BURN_TIM)
            stringBuffer[1] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "BURN_TIM", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # C1  CMOD_COD
        if not err and (<MIR*>self.pRec).CMOD_COD != 0x20:    # hex of SPACE
            sprintf(stringBuffer, "%c", (<MIR*>self.pRec).CMOD_COD)
            stringBuffer[1] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "CMOD_COD", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  LOT_ID
        if not err and (<MIR*>self.pRec).LOT_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "LOT_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).LOT_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  PART_TYP
        if not err and (<MIR*>self.pRec).PART_TYP != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "PART_TYP", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).PART_TYP, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  NODE_NAM
        if not err and (<MIR*>self.pRec).NODE_NAM != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "NODE_NAM", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).NODE_NAM, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  TSTR_TYP
        if not err and (<MIR*>self.pRec).TSTR_TYP != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "TSTR_TYP", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).TSTR_TYP, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  JOB_NAM
        if not err and (<MIR*>self.pRec).JOB_NAM != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "JOB_NAM", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).JOB_NAM, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  JOB_REV
        if not err and (<MIR*>self.pRec).JOB_REV != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "JOB_REV", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).JOB_REV, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  SBLOT_ID
        if not err and (<MIR*>self.pRec).SBLOT_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "SBLOT_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).SBLOT_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  OPER_NAM
        if not err and (<MIR*>self.pRec).OPER_NAM != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "OPER_NAM", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).OPER_NAM, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  EXEC_TYP
        if not err and (<MIR*>self.pRec).EXEC_TYP != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "EXEC_TYP", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).EXEC_TYP, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  EXEC_VER
        if not err and (<MIR*>self.pRec).EXEC_VER != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "EXEC_VER", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).EXEC_VER, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  TEST_COD
        if not err and (<MIR*>self.pRec).TEST_COD != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "TEST_COD", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).TEST_COD, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  TST_TEMP
        if not err and (<MIR*>self.pRec).TST_TEMP != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "TST_TEMP", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).TST_TEMP, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  USER_TXT
        if not err and (<MIR*>self.pRec).USER_TXT != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "USER_TXT", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).USER_TXT, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  AUX_FILE
        if not err and (<MIR*>self.pRec).AUX_FILE != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "AUX_FILE", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).AUX_FILE, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  PKG_TYP
        if not err and (<MIR*>self.pRec).PKG_TYP != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "PKG_TYP", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).PKG_TYP, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  FAMLY_ID
        if not err and (<MIR*>self.pRec).FAMLY_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "FAMLY_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).FAMLY_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  DATE_COD
        if not err and (<MIR*>self.pRec).DATE_COD != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "DATE_COD", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).DATE_COD, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  FACIL_ID
        if not err and (<MIR*>self.pRec).FACIL_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "FACIL_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).FACIL_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  FLOOR_ID
        if not err and (<MIR*>self.pRec).FLOOR_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "FLOOR_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).FLOOR_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  PROC_ID
        if not err and (<MIR*>self.pRec).PROC_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "PROC_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).PROC_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  OPER_FRQ
        if not err and (<MIR*>self.pRec).OPER_FRQ != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "OPER_FRQ", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).OPER_FRQ, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  SPEC_NAM
        if not err and (<MIR*>self.pRec).SPEC_NAM != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "SPEC_NAM", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).SPEC_NAM, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  SPEC_VER
        if not err and (<MIR*>self.pRec).SPEC_VER != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "SPEC_VER", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).SPEC_VER, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  FLOW_ID
        if not err and (<MIR*>self.pRec).FLOW_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "FLOW_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).FLOW_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  SETUP_ID
        if not err and (<MIR*>self.pRec).SETUP_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "SETUP_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).SETUP_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  DSGN_REV
        if not err and (<MIR*>self.pRec).DSGN_REV != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "DSGN_REV", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).DSGN_REV, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  ENG_ID
        if not err and (<MIR*>self.pRec).ENG_ID != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "ENG_ID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).ENG_ID, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  ROM_COD
        if not err and (<MIR*>self.pRec).ROM_COD != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "ROM_COD", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).ROM_COD, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  SERL_NUM
        if not err and (<MIR*>self.pRec).SERL_NUM != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "SERL_NUM", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).SERL_NUM, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        # Cn  SUPR_NAM
        if not err and (<MIR*>self.pRec).SUPR_NAM != NULL:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "SUPR_NAM", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, (<MIR*>self.pRec).SUPR_NAM, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)

        free_record(recHeader, self.pRec)
        return err
                
                
    cdef int onPMR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int err = 0
            uint16_t    PMR_INDX
            char*       CHAN_NAM
            char*       PHY_NAM
            char*       LOG_NAM
            
        parse_record(&self.pRec, recHeader, rawData, binaryLen)

        PMR_INDX = (<PMR*>self.pRec).PMR_INDX
        CHAN_NAM = (<PMR*>self.pRec).CHAN_NAM
        PHY_NAM = (<PMR*>self.pRec).PHY_NAM
        LOG_NAM = (<PMR*>self.pRec).LOG_NAM
        # self.pinDict[PMR_INDX] = [CHAN_NAM, PHY_NAM, LOG_NAM]

        free_record(recHeader, self.pRec)
        return err
    
    
    cdef int onPIR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int err = 0
            uint8_t HEAD_NUM, SITE_NUM

        # used for linking TRs with PRR
        self.dutIndex += 1
        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        HEAD_NUM = (<PIR*>self.pRec).HEAD_NUM
        SITE_NUM = (<PIR*>self.pRec).SITE_NUM
        
        if (MAP_OK != hashmap_put(self.head_site_dutIndex, HEAD_NUM<<8 | SITE_NUM, self.dutIndex)):
            err = MAP_OMEM
        
        if not err:
            sqlite3_bind_int(self.insertDut_stmt, 1, HEAD_NUM)
            sqlite3_bind_int(self.insertDut_stmt, 2, SITE_NUM)
            sqlite3_bind_int(self.insertDut_stmt, 3, self.dutIndex)
            err = csqlite3_step(self.insertDut_stmt)
    
        free_record(recHeader, self.pRec)
        return err
    
    
    cdef int onTR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            uint32_t TEST_NUM, currentDutIndex
            uint8_t HEAD_NUM, SITE_NUM, OPT_FLAG
            int RES_SCAL, err = 0
            double LLimit, HLimit
            bint No_RES_SCAL = False, No_LLimit = False, No_HLimit = False
            char* TEST_TXT
            char* Unit
        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        # read testNum headNum and siteNum
        if recHeader == REC_PTR:
            TEST_NUM = (<PTR*>self.pRec).TEST_NUM
            HEAD_NUM = (<PTR*>self.pRec).HEAD_NUM
            SITE_NUM = (<PTR*>self.pRec).SITE_NUM
        elif recHeader == REC_FTR:
            TEST_NUM = (<FTR*>self.pRec).TEST_NUM
            HEAD_NUM = (<FTR*>self.pRec).HEAD_NUM
            SITE_NUM = (<FTR*>self.pRec).SITE_NUM
        else:
            TEST_NUM = (<MPR*>self.pRec).TEST_NUM
            HEAD_NUM = (<MPR*>self.pRec).HEAD_NUM
            SITE_NUM = (<MPR*>self.pRec).SITE_NUM

        if (MAP_OK != hashmap_get(self.head_site_dutIndex, HEAD_NUM<<8 | SITE_NUM, &currentDutIndex)):
            err = MAP_MISSING

        if not err:
            # insert or replace Test_Offsets
            sqlite3_bind_int(self.insertTR_stmt, 1, currentDutIndex)                # DUTIndex
            sqlite3_bind_int(self.insertTR_stmt, 2, TEST_NUM)                       # TEST_NUM
            sqlite3_bind_int64(self.insertTR_stmt, 3, <sqlite3_int64>self.offset)   # offset
            sqlite3_bind_int(self.insertTR_stmt, 4, binaryLen)                      # BinaryLen
            err = csqlite3_step(self.insertTR_stmt)
        
        # cache omitted fields
        # MUST pre-read and cache OPT_FLAG, RES_SCAL, LLM_SCAL, HLM_SCAL of a test item from the first record
        # as it may be omitted in the later record, causing typeError when user directly selects sites where 
        # no such field value is available in the data preparation.
        if (not err) and (not hashmap_contains(self.seenTN, TEST_NUM)):
            if (MAP_OK != hashmap_put(self.seenTN, TEST_NUM, 0)):
                err = MAP_OMEM

            if recHeader == REC_FTR: # FTR
                No_RES_SCAL = No_LLimit = No_HLimit = True
                TEST_TXT    = (<FTR*>self.pRec).TEST_TXT
                OPT_FLAG    = (<FTR*>self.pRec).OPT_FLAG
                Unit = ""
            elif recHeader == REC_PTR:
                No_RES_SCAL = No_LLimit = No_HLimit = False
                TEST_TXT    = (<PTR*>self.pRec).TEST_TXT
                RES_SCAL    = (<PTR*>self.pRec).RES_SCAL
                LLimit      = (<PTR*>self.pRec).LO_LIMIT
                HLimit      = (<PTR*>self.pRec).HI_LIMIT
                Unit        = (<PTR*>self.pRec).UNITS
                OPT_FLAG    = (<PTR*>self.pRec).OPT_FLAG
            else:
                No_RES_SCAL = No_LLimit = No_HLimit = False
                TEST_TXT    = (<MPR*>self.pRec).TEST_TXT
                RES_SCAL    = (<MPR*>self.pRec).RES_SCAL
                LLimit      = (<MPR*>self.pRec).LO_LIMIT
                HLimit      = (<MPR*>self.pRec).HI_LIMIT
                Unit        = (<MPR*>self.pRec).UNITS
                OPT_FLAG    = (<MPR*>self.pRec).OPT_FLAG

            if Unit == NULL: Unit = ""
            if not err:
                sqlite3_bind_int(self.insertTestInfo_stmt, 1, TEST_NUM)                 # TEST_NUM
                sqlite3_bind_int(self.insertTestInfo_stmt, 2, recHeader)                # recHeader
                sqlite3_bind_text(self.insertTestInfo_stmt, 3, TEST_TXT, -1, NULL)      # TEST_NAME
                if not No_RES_SCAL:
                    sqlite3_bind_int(self.insertTestInfo_stmt, 4, RES_SCAL)             # RES_SCAL
                if not No_LLimit:
                    sqlite3_bind_double(self.insertTestInfo_stmt, 5, LLimit)            # LLimit
                if not No_HLimit:
                    sqlite3_bind_double(self.insertTestInfo_stmt, 6, HLimit)            # HLimit
                sqlite3_bind_text(self.insertTestInfo_stmt, 7, Unit, -1, NULL)          # Unit
                sqlite3_bind_int(self.insertTestInfo_stmt, 8, OPT_FLAG)                 # OPT_FLAG
                sqlite3_bind_int(self.insertTestInfo_stmt, 9, -1)                       # FailCnt, default -1
                err = csqlite3_step(self.insertTestInfo_stmt)
        free_record(recHeader, self.pRec)
        return err
                            
            
    cdef int onPRR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            bint No_Wafer = False
            uint8_t HEAD_NUM, SITE_NUM, PART_FLG
            uint32_t currentDutIndex, currentWaferIndex
            int HARD_BIN, SOFT_BIN, NUM_TEST, X_COORD, Y_COORD, TEST_T, err = 0
            char* PART_ID
        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        HEAD_NUM    = (<PRR*>self.pRec).HEAD_NUM
        SITE_NUM    = (<PRR*>self.pRec).SITE_NUM
        HARD_BIN    = (<PRR*>self.pRec).HARD_BIN
        SOFT_BIN    = (<PRR*>self.pRec).SOFT_BIN
        PART_FLG    = (<PRR*>self.pRec).PART_FLG
        NUM_TEST    = (<PRR*>self.pRec).NUM_TEST
        X_COORD     = (<PRR*>self.pRec).X_COORD
        Y_COORD     = (<PRR*>self.pRec).Y_COORD
        TEST_T      = (<PRR*>self.pRec).TEST_T
        PART_ID     = (<PRR*>self.pRec).PART_ID

        if (MAP_OK != hashmap_get(self.head_site_dutIndex, HEAD_NUM<<8 | SITE_NUM, &currentDutIndex)):
            err = MAP_MISSING
        
        if hashmap_contains(self.head_waferIndex, HEAD_NUM):
            No_Wafer = False
            if (MAP_OK != hashmap_get(self.head_waferIndex, HEAD_NUM, &currentWaferIndex)):
                err = MAP_MISSING
        else:
            No_Wafer = True

        if PART_ID == NULL: PART_ID = ""
        if not err:
            sqlite3_bind_int(self.updateDut_stmt, 1, NUM_TEST)                      # TestCount
            sqlite3_bind_int(self.updateDut_stmt, 2, TEST_T)                        # TestTime
            sqlite3_bind_text(self.updateDut_stmt, 3, PART_ID, -1, NULL)            # PartID
            sqlite3_bind_int(self.updateDut_stmt, 4, HARD_BIN)                      # HBIN_NUM
            sqlite3_bind_int(self.updateDut_stmt, 5, SOFT_BIN)                      # SBIN_NUM
            sqlite3_bind_int(self.updateDut_stmt, 6, PART_FLG)                      # Flag
            if not No_Wafer:
                sqlite3_bind_int(self.updateDut_stmt, 7, currentWaferIndex)         # WaferIndex
            else:
                sqlite3_bind_null(self.updateDut_stmt, 7)
            if X_COORD != -32768:
                sqlite3_bind_int(self.updateDut_stmt, 8, X_COORD)                   # XCOORD
            else:
                sqlite3_bind_null(self.updateDut_stmt, 8)
            if Y_COORD != -32768:
                sqlite3_bind_int(self.updateDut_stmt, 9, Y_COORD)                   # YCOORD
            else:
                sqlite3_bind_null(self.updateDut_stmt, 9)
            sqlite3_bind_int(self.updateDut_stmt, 10, currentDutIndex)              # DUTIndex
            err = csqlite3_step(self.updateDut_stmt)
        
        # we can determine the type of hard/soft bin based on the part_flag
        # it is helpful if the std is incomplete and lack of HBR/SBR
        # if key is existed, do not update repeatedly        
        if not err: 
            sqlite3_bind_int(self.insertHBIN_stmt, 1, HARD_BIN)                                         # HBIN_NUM
            sqlite3_bind_text(self.insertHBIN_stmt, 2, "MissingName", -1, NULL)     # HBIN_NAME
            if PART_FLG & 0b00011000 == 0:
                sqlite3_bind_text(self.insertHBIN_stmt, 3, "P", -1, NULL)  # PF
            elif PART_FLG & 0b00010000 == 0:
                sqlite3_bind_text(self.insertHBIN_stmt, 3, "F", -1, NULL)  # PF
            else:
                sqlite3_bind_text(self.insertHBIN_stmt, 3, "U", -1, NULL)  # PF
            err = csqlite3_step(self.insertHBIN_stmt)

        if not err: 
            sqlite3_bind_int(self.insertSBIN_stmt, 1, SOFT_BIN)                                         # SBIN_NUM
            sqlite3_bind_text(self.insertSBIN_stmt, 2, "MissingName", -1, NULL)     # SBIN_NAME
            if PART_FLG & 0b00011000 == 0:
                sqlite3_bind_text(self.insertSBIN_stmt, 3, "P", -1, NULL)  # PF
            elif PART_FLG & 0b00010000 == 0:
                sqlite3_bind_text(self.insertSBIN_stmt, 3, "F", -1, NULL)  # PF
            else:
                sqlite3_bind_text(self.insertSBIN_stmt, 3, "U", -1, NULL)  # PF
            err = csqlite3_step(self.insertSBIN_stmt)
        free_record(recHeader, self.pRec)
        return err
            
        
    cdef int onHBR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int HBIN_NUM, err = 0
            char* HBIN_NAM
            char  HBIN_PF[2]
        # This method is used for getting bin num/names/PF
        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        # SITE_NUM = valueDict["SITE_NUM"]
        HBIN_NUM = (<HBR*>self.pRec).HBIN_NUM
        sprintf(HBIN_PF, "%c", (<HBR*>self.pRec).HBIN_PF)
        HBIN_PF[1] = 0x00
        HBIN_NAM = (<HBR*>self.pRec).HBIN_NAM
        # use the count from PRR as default, in case the file is incomplete
        # HBIN_CNT = valueDict["HBIN_CNT"]
        if HBIN_PF[0] != 0x46 and HBIN_PF[0] != 0x50:
            # not 'F' nor 'P', write default 'U'
            HBIN_PF[0] = 0x55
        if HBIN_NAM == NULL:
            HBIN_NAM = "MissingName"

        if not err: 
            sqlite3_bind_int(self.insertHBIN_stmt, 1, HBIN_NUM)               # HBIN_NUM
            sqlite3_bind_text(self.insertHBIN_stmt, 2, HBIN_NAM, -1, NULL)    # HBIN_NAME
            sqlite3_bind_text(self.insertHBIN_stmt, 3, HBIN_PF, -1, NULL)     # PF
            err = csqlite3_step(self.insertHBIN_stmt)
        free_record(recHeader, self.pRec)
        return err
       
        
    cdef int onSBR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int SBIN_NUM, err = 0
            char* SBIN_NAM
            char  SBIN_PF[2]
        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        # SITE_NUM = valueDict["SITE_NUM"]
        SBIN_NUM = (<SBR*>self.pRec).SBIN_NUM
        sprintf(SBIN_PF, "%c", (<SBR*>self.pRec).SBIN_PF)
        SBIN_PF[1] = 0x00
        SBIN_NAM = (<SBR*>self.pRec).SBIN_NAM
        if SBIN_PF[0] != 0x46 and SBIN_PF[0] != 0x50:
            # not 'F' nor 'P', write default 'U'
            SBIN_PF[0] = 0x55
        if SBIN_NAM == NULL:
            SBIN_NAM = "MissingName"
        
        if not err: 
            sqlite3_bind_int(self.insertSBIN_stmt, 1, SBIN_NUM)               # SBIN_NUM
            sqlite3_bind_text(self.insertSBIN_stmt, 2, SBIN_NAM, -1, NULL)    # SBIN_NAME
            sqlite3_bind_text(self.insertSBIN_stmt, 3, SBIN_PF, -1, NULL)     # PF
            err = csqlite3_step(self.insertSBIN_stmt)        
        free_record(recHeader, self.pRec)
        return err


    cdef int onWCR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int err = 0
            double WAFR_SIZ, DIE_HT, DIE_WID
            uint8_t WF_UNITS, 
            int16_t CENTER_X, CENTER_Y
            char WF_FLAT[2]
            char POS_X[2]
            char POS_Y[2]
            char stringBuffer[100]
            int bufferLen

        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        WAFR_SIZ = (<WCR*>self.pRec).WAFR_SIZ
        DIE_HT = (<WCR*>self.pRec).DIE_HT
        DIE_WID = (<WCR*>self.pRec).DIE_WID
        WF_UNITS = (<WCR*>self.pRec).WF_UNITS
        sprintf(WF_FLAT, "%c", (<WCR*>self.pRec).WF_FLAT)
        CENTER_X = (<WCR*>self.pRec).CENTER_X
        CENTER_Y = (<WCR*>self.pRec).CENTER_Y
        sprintf(POS_X, "%c", (<WCR*>self.pRec).POS_X)
        sprintf(POS_Y, "%c", (<WCR*>self.pRec).POS_Y)
        WF_FLAT[1] = POS_X[1] = POS_Y[1] = 0x00

        # WAFR_SIZ
        if not err and WAFR_SIZ != 0:
            bufferLen = sprintf(stringBuffer, "%g", WAFR_SIZ)
            if bufferLen < 0: stringBuffer[0] = 0x00
            else: stringBuffer[bufferLen] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "WAFR_SIZ", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
        
        # DIE_HT
        if not err and DIE_HT != 0:
            bufferLen = sprintf(stringBuffer, "%g", DIE_HT)
            if bufferLen < 0: stringBuffer[0] = 0x00
            else: stringBuffer[bufferLen] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "DIE_HT", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
            
        # DIE_WID
        if not err and DIE_WID != 0:
            bufferLen = sprintf(stringBuffer, "%g", DIE_WID)
            if bufferLen < 0: stringBuffer[0] = 0x00
            else: stringBuffer[bufferLen] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "DIE_WID", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
            
        # WF_UNITS
        if not err and WF_UNITS != 0:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "WF_UNITS", -1, NULL)
            if WF_UNITS == 1:   # inches
                sqlite3_bind_text(self.insertFileInfo_stmt, 2, "inch", -1, NULL)
            elif WF_UNITS == 2:   # cm
                sqlite3_bind_text(self.insertFileInfo_stmt, 2, "cm", -1, NULL)
            elif WF_UNITS == 3:   # mm
                sqlite3_bind_text(self.insertFileInfo_stmt, 2, "mm", -1, NULL)
            else:   # mil
                sqlite3_bind_text(self.insertFileInfo_stmt, 2, "mil", -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)

        # WF_FLAT
        if not err:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "WF_FLAT", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, WF_FLAT, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
            
        # CENTER_X
        if not err and CENTER_X != -32768:
            bufferLen = sprintf(stringBuffer, "%d", CENTER_X)
            if bufferLen < 0: stringBuffer[0] = 0x00
            else: stringBuffer[bufferLen] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "CENTER_X", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
            
        # CENTER_Y
        if not err and CENTER_Y != -32768:
            bufferLen = sprintf(stringBuffer, "%d", CENTER_Y)
            if bufferLen < 0: stringBuffer[0] = 0x00
            else: stringBuffer[bufferLen] = 0x00
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "CENTER_Y", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, stringBuffer, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)
                        
        # POS_X
        if not err:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "POS_X", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, POS_X, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)

        # POS_Y
        if not err:
            sqlite3_bind_text(self.insertFileInfo_stmt, 1, "POS_Y", -1, NULL)
            sqlite3_bind_text(self.insertFileInfo_stmt, 2, POS_Y, -1, NULL)
            err = csqlite3_step(self.insertFileInfo_stmt)

        return err
    
    
    cdef int onWIR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int err = 0
            uint8_t HEAD_NUM
            char* WAFER_ID

        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        HEAD_NUM = (<WIR*>self.pRec).HEAD_NUM
        WAFER_ID = (<WIR*>self.pRec).WAFER_ID
        self.waferIndex += 1
        if (MAP_OK != hashmap_put(self.head_waferIndex, HEAD_NUM, self.waferIndex)):
            err = MAP_MISSING
        
        # the following info is also available in WRR, but it still should be updated
        # in WIR in case the stdf is incomplete (no WRR).
        if not err:
            sqlite3_bind_int(self.insertWafer_stmt, 1, HEAD_NUM)                 # HEAD_NUM
            sqlite3_bind_int(self.insertWafer_stmt, 2, self.waferIndex)          # WaferIndex
            sqlite3_bind_text(self.insertWafer_stmt, 8, WAFER_ID, -1, NULL)      # WaferID
            err = csqlite3_step(self.insertWafer_stmt)
        free_record(recHeader, self.pRec)
        return err
    
    
    cdef int onWRR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int err = 0
            uint8_t HEAD_NUM
            uint32_t currentWaferIndex, PART_CNT, RTST_CNT, ABRT_CNT, GOOD_CNT, FUNC_CNT
            char* WAFER_ID
            char* FABWF_ID
            char* FRAME_ID
            char* MASK_ID
            char* USR_DESC
            char* EXC_DESC

        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        HEAD_NUM = (<WRR*>self.pRec).HEAD_NUM
        PART_CNT = (<WRR*>self.pRec).PART_CNT
        RTST_CNT = (<WRR*>self.pRec).RTST_CNT
        ABRT_CNT = (<WRR*>self.pRec).ABRT_CNT
        GOOD_CNT = (<WRR*>self.pRec).GOOD_CNT
        FUNC_CNT = (<WRR*>self.pRec).FUNC_CNT
        WAFER_ID = (<WRR*>self.pRec).WAFER_ID
        FABWF_ID = (<WRR*>self.pRec).FABWF_ID
        FRAME_ID = (<WRR*>self.pRec).FRAME_ID
        MASK_ID = (<WRR*>self.pRec).MASK_ID
        USR_DESC = (<WRR*>self.pRec).USR_DESC
        EXC_DESC = (<WRR*>self.pRec).EXC_DESC

        if (MAP_OK != hashmap_get(self.head_waferIndex, HEAD_NUM, &currentWaferIndex)):
            err = MAP_MISSING

        if not err:
            sqlite3_bind_int(self.insertWafer_stmt, 1, HEAD_NUM)                # HEAD_NUM
            sqlite3_bind_int(self.insertWafer_stmt, 2, currentWaferIndex)       # WaferIndex
            sqlite3_bind_int(self.insertWafer_stmt, 3, PART_CNT)                # PART_CNT
            if RTST_CNT != <uint32_t>0xFFFFFFFF:
                sqlite3_bind_int(self.insertWafer_stmt, 4, RTST_CNT)            # RTST_CNT
            else:
                sqlite3_bind_int(self.insertWafer_stmt, 4, -1)

            if ABRT_CNT != <uint32_t>0xFFFFFFFF:
                sqlite3_bind_int(self.insertWafer_stmt, 5, ABRT_CNT)            # ABRT_CNT
            else:
                sqlite3_bind_int(self.insertWafer_stmt, 5, -1)

            if GOOD_CNT != <uint32_t>0xFFFFFFFF:
                sqlite3_bind_int(self.insertWafer_stmt, 6, GOOD_CNT)            # GOOD_CNT
            else:
                sqlite3_bind_int(self.insertWafer_stmt, 6, -1)

            if FUNC_CNT != <uint32_t>0xFFFFFFFF:
                sqlite3_bind_int(self.insertWafer_stmt, 7, FUNC_CNT)            # FUNC_CNT
            else:
                sqlite3_bind_int(self.insertWafer_stmt, 7, -1)

            sqlite3_bind_text(self.insertWafer_stmt, 8, WAFER_ID, -1, NULL)     # WAFER_ID
            sqlite3_bind_text(self.insertWafer_stmt, 9, FABWF_ID, -1, NULL)     # FABWF_ID
            sqlite3_bind_text(self.insertWafer_stmt, 10, FRAME_ID, -1, NULL)    # FRAME_ID
            sqlite3_bind_text(self.insertWafer_stmt, 11, MASK_ID, -1, NULL)     # MASK_ID
            sqlite3_bind_text(self.insertWafer_stmt, 12, USR_DESC, -1, NULL)    # USR_DESC
            sqlite3_bind_text(self.insertWafer_stmt, 13, EXC_DESC, -1, NULL)    # EXC_DESC
            err = csqlite3_step(self.insertWafer_stmt)

        free_record(recHeader, self.pRec)
        return err

    
    cdef int onTSR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int err = 0
            uint32_t TEST_NUM, FAIL_CNT, tmpCount
        # for fast find failed test number globally
        # don't care about head number nor site number
        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        TEST_NUM = (<TSR*>self.pRec).TEST_NUM
        FAIL_CNT = (<TSR*>self.pRec).FAIL_CNT

        if FAIL_CNT != <uint32_t>0xFFFFFFFF:          # 2**32-1 invalid number for FAIL_CNT
            if hashmap_contains(self.TestFailCount, TEST_NUM):
                # get previous count and add up
                if (MAP_OK != hashmap_get(self.TestFailCount, TEST_NUM, &tmpCount)):
                    err = MAP_MISSING
                    return err

                tmpCount += FAIL_CNT
                if (MAP_OK != hashmap_put(self.TestFailCount, TEST_NUM, tmpCount)):
                    err = MAP_OMEM
            else:
                # save current count
                if (MAP_OK != hashmap_put(self.TestFailCount, TEST_NUM, FAIL_CNT)):
                    err = MAP_OMEM
        return err


    cdef int onPCR(self, uint16_t recHeader, uint16_t binaryLen, unsigned char* rawData) nogil:
        cdef:
            int err = 0
            uint8_t HEAD_NUM, SITE_NUM
            uint32_t PART_CNT, RTST_CNT, ABRT_CNT, GOOD_CNT, FUNC_CNT

        parse_record(&self.pRec, recHeader, rawData, binaryLen)
        HEAD_NUM = (<PCR*>self.pRec).HEAD_NUM
        SITE_NUM = (<PCR*>self.pRec).SITE_NUM
        PART_CNT = (<PCR*>self.pRec).PART_CNT
        RTST_CNT = (<PCR*>self.pRec).RTST_CNT
        ABRT_CNT = (<PCR*>self.pRec).ABRT_CNT
        GOOD_CNT = (<PCR*>self.pRec).GOOD_CNT
        FUNC_CNT = (<PCR*>self.pRec).FUNC_CNT
        
        sqlite3_bind_int(self.insertDutCount_stmt, 1, HEAD_NUM)                # HEAD_NUM
        sqlite3_bind_int(self.insertDutCount_stmt, 2, SITE_NUM)                # SITE_NUM
        sqlite3_bind_int(self.insertDutCount_stmt, 3, PART_CNT)                # PART_CNT
        if RTST_CNT != <uint32_t>0xFFFFFFFF:
            sqlite3_bind_int(self.insertDutCount_stmt, 4, RTST_CNT)            # RTST_CNT
        else:
            sqlite3_bind_int(self.insertDutCount_stmt, 4, -1)

        if ABRT_CNT != <uint32_t>0xFFFFFFFF:
            sqlite3_bind_int(self.insertDutCount_stmt, 5, ABRT_CNT)            # ABRT_CNT
        else:
            sqlite3_bind_int(self.insertDutCount_stmt, 5, -1)

        if GOOD_CNT != <uint32_t>0xFFFFFFFF:
            sqlite3_bind_int(self.insertDutCount_stmt, 6, GOOD_CNT)            # GOOD_CNT
        else:
            sqlite3_bind_int(self.insertDutCount_stmt, 6, -1)

        if FUNC_CNT != <uint32_t>0xFFFFFFFF:
            sqlite3_bind_int(self.insertDutCount_stmt, 7, FUNC_CNT)            # FUNC_CNT
        else:
            sqlite3_bind_int(self.insertDutCount_stmt, 7, -1)

        err = csqlite3_step(self.insertDutCount_stmt)
        return err    

    
class stdfDataRetriever:
    def __init__(self, filepath, dbPath, QSignal=None, flag=None):
        self.summarizer = stdfSummarizer(QSignal=QSignal, flag=flag, filepath=filepath, dbPath=dbPath)            