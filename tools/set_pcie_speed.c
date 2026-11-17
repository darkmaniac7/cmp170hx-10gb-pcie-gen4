/*
 * set_pcie_speed.c: CMP 170HX Gen3 RM link-speed trainer.
 * Source: lixiangwuxian/170hx_tips Gen3_unlock_en.md (reference driver 615.71.09).
 * Requests a speed change through NVIDIA RM so the driver performs link training.
 * Inputs 1/2/3 mean Gen1/Gen2/Gen3; 0 only queries the mapping.
 * DO NOT pass 2500, 5000, or 8000.
 *
 * Compile from the root of the matching open-gpu-kernel-modules source tree:
 *   cc -std=gnu11 -O2 -Wall -Wextra -Isrc/common/sdk/nvidia/inc \
 *      set_pcie_speed.c -o set_pcie_speed
 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <string.h>
#include "nvos.h"
#include "class/cl0080.h"
#include "ctrl/ctrl0000/ctrl0000gpu.h"

#define RM_ALLOC_CMD(t)   _IOWR('F', 0x2B, t)
#define RM_CONTROL_CMD(t) _IOWR('F', 0x2A, t)

#define NV2080_CTRL_CMD_BUS_SET_PCIE_SPEED   0x20801805

typedef struct {
    NvU32 busSpeed;
} SET_SPEED_PARAMS;

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <0|1|2|3> <device-minor> <PCI-bus-hex>\n", argv[0]);
        return 2;
    }
    NvU32 mbps = strtoul(argv[1], NULL, 10);
    if (strlen(argv[1]) != 1 || argv[1][0] < '0' || argv[1][0] > '3') return 2;
    int minor = argc > 2 ? atoi(argv[2]) : 0;

    char devpath[32];
    snprintf(devpath, sizeof(devpath), "/dev/nvidia%d", minor);
    int gfd = open(devpath, O_RDWR);
    if (gfd < 0) { perror(devpath); return 1; }

    int fd = open("/dev/nvidiactl", O_RDWR);
    if (fd < 0) { perror("open /dev/nvidiactl"); return 1; }

    struct { int rc; unsigned status; } completion = {0};
    if (ioctl(gfd, _IOWR('F', 218, typeof(completion)), &completion) < 0 || completion.rc || completion.status) {
        fprintf(stderr,"GPU open failed rc=%d status=0x%x\n",completion.rc,completion.status); return 1;
    }
    int control_fd = fd;
    if (ioctl(gfd, _IOWR('F', 201, int), &control_fd) < 0) {
        perror("register control fd"); return 1;
    }

    NVOS21_PARAMETERS p21;

    /* root client (RM generates the handle) */
    memset(&p21, 0, sizeof(p21));
    p21.hRoot = 0; p21.hObjectParent = 0; p21.hObjectNew = 0; p21.hClass = 0;
    if (ioctl(fd, RM_ALLOC_CMD(NVOS21_PARAMETERS), &p21) || p21.status) {
        fprintf(stderr, "root alloc failed status=0x%x\n", p21.status);
        return 1;
    }
    NvHandle hClient = p21.hObjectNew;

    NV0000_CTRL_GPU_GET_ATTACHED_IDS_PARAMS ids;
    memset(&ids, 0xff, sizeof(ids));
    NVOS54_PARAMETERS query = {0};
    query.hClient=hClient; query.hObject=hClient;
    query.cmd=NV0000_CTRL_CMD_GPU_GET_ATTACHED_IDS;
    query.params=&ids; query.paramsSize=sizeof(ids);
    if (ioctl(fd,RM_CONTROL_CMD(NVOS54_PARAMETERS),&query) || query.status) return 1;
    unsigned targetBus=strtoul(argv[3],NULL,16), instance=~0U;
    for(unsigned i=0;i<32 && ids.gpuIds[i]!=~0U;i++) {
        NV0000_CTRL_GPU_GET_PCI_INFO_PARAMS pci={0}; pci.gpuId=ids.gpuIds[i];
        query.cmd=NV0000_CTRL_CMD_GPU_GET_PCI_INFO; query.params=&pci; query.paramsSize=sizeof(pci); query.status=0;
        if(ioctl(fd,RM_CONTROL_CMD(NVOS54_PARAMETERS),&query) || query.status) return 1;
        if(pci.domain || pci.bus!=targetBus || pci.slot) continue;
        NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS info={0}; info.gpuId=pci.gpuId;
        query.cmd=NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2; query.params=&info; query.paramsSize=sizeof(info); query.status=0;
        if(ioctl(fd,RM_CONTROL_CMD(NVOS54_PARAMETERS),&query) || query.status) return 1;
        if (info.subDeviceInstance != 0) {
            fprintf(stderr,"Nonzero subdevice instance is unsupported\n"); return 1;
        }
        instance=info.deviceInstance;
        printf("bus=%02x gpuId=%x deviceInstance=%u gpuInstance=%u minor=%d\n",pci.bus,pci.gpuId,instance,info.gpuInstance,minor);
        break;
    }
    if(instance==~0U) { fprintf(stderr,"GPU bus not found\n"); return 1; }
    if(mbps==0) return 0;
    /* NV01_DEVICE_0, gpuInstance 0 */
    NV0080_ALLOC_PARAMETERS devParms;
    memset(&devParms, 0, sizeof(devParms));
    devParms.deviceId = instance;
    memset(&p21, 0, sizeof(p21));
    p21.hRoot = hClient; p21.hObjectParent = hClient;
    p21.hObjectNew = 0; p21.hClass = 0x80;      /* NV01_DEVICE_0 */
    p21.pAllocParms = &devParms; p21.paramsSize = sizeof(devParms);
    if (ioctl(fd, RM_ALLOC_CMD(NVOS21_PARAMETERS), &p21) || p21.status) {
        fprintf(stderr, "device alloc failed status=0x%x\n", p21.status);
        return 1;
    }
    NvHandle hDevice = p21.hObjectNew;

    /* NV20_SUBDEVICE_0 */
    memset(&p21, 0, sizeof(p21));
    p21.hRoot = hClient; p21.hObjectParent = hDevice;
    p21.hObjectNew = 0; p21.hClass = 0x2080;
    if (ioctl(fd, RM_ALLOC_CMD(NVOS21_PARAMETERS), &p21) || p21.status) {
        fprintf(stderr, "subdevice alloc failed status=0x%x\n", p21.status);
        return 1;
    }
    NvHandle hSubdevice = p21.hObjectNew;

    /* SET_PCIE_SPEED: paramsSize MUST be exactly 4 */
    SET_SPEED_PARAMS sp = { mbps };
    NVOS54_PARAMETERS p54;
    memset(&p54, 0, sizeof(p54));
    p54.hClient    = hClient;
    p54.hObject    = hSubdevice;
    p54.cmd        = NV2080_CTRL_CMD_BUS_SET_PCIE_SPEED;
    p54.params     = &sp;
    p54.paramsSize = sizeof(sp);

    if (ioctl(fd, RM_CONTROL_CMD(NVOS54_PARAMETERS), &p54) != 0 || p54.status != 0) {
        fprintf(stderr, "SET_PCIE_SPEED failed status=0x%x\n", p54.status);
        return 1;
    }
    printf("SET_PCIE_SPEED(%u) OK\n", mbps);
    return 0;
}
