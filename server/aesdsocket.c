#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <syslog.h>
#include <unistd.h>

#define PORT 9000
#define DATA_FILE "/var/tmp/aesdsocketdata"
#define BUFFER_SIZE 1024

static volatile sig_atomic_t exit_requested = 0;
static int server_fd = -1;

void signal_handler(int signo)
{
    (void)signo;
    exit_requested = 1;
}

void cleanup(void)
{
    if (server_fd != -1)
        close(server_fd);

    remove(DATA_FILE);
    closelog();
}

int main(int argc, char *argv[])
{
    bool daemon_mode = false;

    if ((argc == 2) && (strcmp(argv[1], "-d") == 0))
    {
        daemon_mode = true;
    }

    openlog("aesdsocket", 0, LOG_USER);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;

    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0)
    {
        perror("socket");
        return -1;
    }

    int optval = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));

    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(PORT);

    if (bind(server_fd,
             (struct sockaddr *)&server_addr,
             sizeof(server_addr)) < 0)
    {
        perror("bind");
        cleanup();
        return -1;
    }

    if (listen(server_fd, 5) < 0)
    {
        perror("listen");
        cleanup();
        return -1;
    }

    if (daemon_mode)
    {
        pid_t pid = fork();

        if (pid < 0)
        {
            cleanup();
            return -1;
        }

        if (pid > 0)
        {
            exit(EXIT_SUCCESS);
        }

        if (setsid() < 0)
        {
            cleanup();
            return -1;
        }

        chdir("/");

        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
    }

    while (!exit_requested)
    {
        struct sockaddr_in client_addr;
        socklen_t addrlen = sizeof(client_addr);

        int client_fd =
            accept(server_fd,
                   (struct sockaddr *)&client_addr,
                   &addrlen);

        if (client_fd < 0)
        {
            if (exit_requested)
                break;

            continue;
        }

        char client_ip[INET_ADDRSTRLEN];

        inet_ntop(AF_INET,
                  &client_addr.sin_addr,
                  client_ip,
                  sizeof(client_ip));

        syslog(LOG_DEBUG,
               "Accepted connection from %s",
               client_ip);

        char *packet = NULL;
        size_t total_size = 0;

        while (1)
        {
            char buffer[BUFFER_SIZE];

            ssize_t bytes =
                recv(client_fd,
                     buffer,
                     sizeof(buffer),
                     0);

            if (bytes <= 0)
                break;

            char *temp =
                realloc(packet,
                        total_size + bytes + 1);

            if (!temp)
            {
                free(packet);
                packet = NULL;
                break;
            }

            packet = temp;

            memcpy(packet + total_size,
                   buffer,
                   bytes);

            total_size += bytes;
            packet[total_size] = '\0';

            if (memchr(buffer, '\n', bytes))
                break;
        }

        if (packet)
        {
            FILE *fp = fopen(DATA_FILE, "a");

            if (fp)
            {
                fwrite(packet,
                       1,
                       total_size,
                       fp);

                fclose(fp);
            }

            free(packet);

            fp = fopen(DATA_FILE, "r");

            if (fp)
            {
                char sendbuf[BUFFER_SIZE];
                size_t bytes_read;

                while ((bytes_read =
                            fread(sendbuf,
                                  1,
                                  sizeof(sendbuf),
                                  fp)) > 0)
                {
                    send(client_fd,
                         sendbuf,
                         bytes_read,
                         0);
                }

                fclose(fp);
            }
        }

        close(client_fd);

        syslog(LOG_DEBUG,
               "Closed connection from %s",
               client_ip);
    }

    syslog(LOG_DEBUG,
           "Caught signal, exiting");

    cleanup();

    return 0;
}
