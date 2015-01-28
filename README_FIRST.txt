=========================================================================================
Due to the fact that moving a complete guest could take much time I suggest to implement,
on your Oracle VM Manager server, a sort of keep-alive, based on ssh-client timeout.
=========================================================================================
=======================================================================
= Here how to change the default "ssh client" timeout on Oracle Linux =
=======================================================================
Edit the file "/etc/ssh/ssh_config" and add:
        ServerAliveInterval 60

Example (add at least a "space" before the new parameter)::
##################################
...
....
.....
Host *
        GSSAPIAuthentication yes
        ServerAliveInterval 20
.....
....
...
##################################
