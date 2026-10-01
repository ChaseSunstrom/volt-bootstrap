/* packet.h: a union, bitfields and an anonymous member, for the C interop page */
typedef union {
    unsigned int word;
    unsigned char bytes[4];
} raw32;

struct header {
    unsigned int version : 4;
    unsigned int urgent : 1;
    struct {
        unsigned short port;
        unsigned short length;
    };
    raw32 checksum;
};
