from django.contrib.auth.views import LoginView
from django.contrib.auth import logout
from django.shortcuts import redirect


class ManagerLoginView(LoginView):
    template_name = "manager_login.html"
    redirect_authenticated_user = True

    def get_success_url(self):
        return "/manager/today/"


def manager_logout(request):
    logout(request)
    return redirect("/manager/login/")
